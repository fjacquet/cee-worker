# CEE 9.3.0.0 on Windows Server 2025 — measured findings

Second bring-up, 2026-08-14, from `epg` (10.26.1.221) driving `cee-win25`
(`win25.diab.local`, 10.26.1.199, Windows Server 2025 Datacenter, CEE
**9.3.0.0**). The same two arrays were in scope as the first bring-up:
PowerStore `diabps01` (NAS server NAS01, `nas01.diab.local`, 10.26.1.224) and
the 4-node PowerScale `powerscale1` (OneFS 9.13.0.0, nodes 10.26.1.150–.153).

Read `cepa-bring-up-findings.md` first — this document assumes it and does not
repeat it. Where a claim here is an inference rather than a measurement, it
says so.

**Outcome (2026-08-14): PowerScale now delivers events end to end, and CEE is
not in that path.** OneFS speaks CEPA directly to cee-exporter. CEE 9.3 rejects
the same cluster's heartbeat outright. PowerStore remains unproven and, since
being repointed, has stopped heartbeating any CEE host at all.

> **PowerStore is no longer unproven.** On 2026-08-22 it delivered events end to
> end through CEE 9.3 on this same host. The blocker was CEE refusing to
> register the consumer — see `cepa-2026-08-22-powerstore-session.md`.

> **Superseded — read `cepa-2026-08-22-powerstore-session.md` instead.** A
> draft of this note claimed the `CEPP_NOT_FOUND` was caused by `cee-exporter`
> answering CEE's registration with an empty body. That was disproved the next
> day by a control: pointing CEE at a dead endpoint produces the identical
> `0x16`. The consumer leg is not the cause. The `CHECK$` lead this document
> ends on is NOT it either — CEE never opens that share. **The cause was CEE's
> partner allowlist; solved 2026-08-22.**
>
> Several host facts below are also stale; the newer document lists them.

## CEE serves `/vee`; OneFS posts to `/`

**Corrected later the same day.** This section first concluded that CEE 9.3
rejects OneFS outright. That was wrong, and the way it was wrong is worth
keeping: the evidence was a capture full of 400s, and a capture shows only
that a request failed, never why.

CEE's CEPA endpoint is the path **`/vee`**, which is what PowerStore posts to.
OneFS posts to `/`. Measured against CEE 9.3 with an identical OneFS payload:

| Request | Reply |
|---|---|
| `PUT /` | 400 Bad Request |
| `POST /` | 400 Bad Request |
| `PUT /vee` | **200 OK**, well-formed `CheckFileResponse` |
| `POST /vee` | **200 OK**, well-formed `CheckFileResponse` |

So the 400s were a path mismatch, not a dialect incompatibility and not a
version regression. On `/vee`, CEE parses the OneFS heartbeat and answers it
properly — with `status="0x16"`, the same status it gives PowerStore, which
is a different problem entirely (see below).

Also ruled out along the way: the theory in `cepa-bring-up-findings.md` that
CEE wanted a UNC-shaped name from OneFS. Sending the cluster name base64'd as
`\\powerscale1.diab.local\CHECK$` instead of the bare `powerscale1` changed
nothing — `0x16` either way.

Whether OneFS can be pointed at a path (`--cee-server-uris=http://host:12228/vee`)
is untested.

### The original observation, kept for the record

Every PowerScale heartbeat sent to CEE 9.3 **on `/`** was answered
`HTTP/1.1 400 Bad Request` — 258 of 258 in one capture, 134 of 134 in a
second, from all four node addresses. The requests are well-formed:

```
PUT / HTTP/1.1
Host: win25.diab.local:12228
Accept: */*
Content-Type: text/xml
Content-Length: 233

<CheckFileRequest><Args action="9" sourceIP="10.26.1.151" sourceID="2"
  name="…"><Cluster id="…" name="…"/></Args></CheckFileRequest>
```

CEE never reaches its CEPA parser: the reply is an 89-byte HTML error page,
not a `CheckFileResponse`. That matters because the first bring-up recorded 9.2
returning a *parsed* `CheckFileResponse` with `status="0x1"` / `"0x16"` — an
error, but one OneFS could read.

**Not established: whether this is a 9.3 regression.** Replaying a captured
heartbeat byte-for-byte drew `400` from *both* 9.2.0.0 on SLES and 9.3.0.0 on
Windows, which means the replay differs from real cluster traffic in some way
that matters — most likely that it carried `sourceIP="10.26.1.151"` while
originating from 10.26.1.221. A clean comparison needs real cluster traffic
pointed at a 9.2 host, and that experiment was dropped as not worth running:
nothing about this deployment requires CEE in the PowerScale path.

Useful side effect of the replay: CEE identifies its build in the response
header, so `Server: CEE Server 9.3.0.0` is a one-line way to confirm which
version answered.

**No events were lost to this.** Only heartbeats (`action="9"`) were ever sent
to CEE; every `action="11"` event went to the consumer. OneFS evidently will
not forward events to a server whose heartbeat it cannot complete.

## The Windows debugging method from the first bring-up does not exist

> **Wrong on both counts, corrected 2026-08-22.** Windows CEE *does* emit a
> trace — to `OutputDebugString` (the `DBWIN_BUFFER` channel Sysinternals
> DebugView reads), not to the Application event log this section searched. And
> `Debug=1` is far too low: `Debug`/`Verbose` are a 6-bit mask where `9` prints
> less than `3` and only **63** names the reason CEE refuses a partner. The
> conclusion below — "the wire is the only instrument" — sent two bring-ups
> looking at packets when CEE would have said what was wrong. See
> `cepa-protocol.md`.

`cepa-bring-up-findings.md` establishes that CEE 9.2 writes nothing to the
journal at the shipped `Debug=0`/`Verbose=0`, and that every root cause in that
document came from turning both on. **On Windows there is no equivalent to
turn on.**

Measured with `Debug=1` and `Verbose=1` set in the registry and the service
restarted: while CAVA.exe demonstrably dispatched a register request to the
consumer every 10 seconds — each one logged at the consumer, so the traffic is
not in doubt — the host recorded five Application-log entries, all lifecycle
(`104` starting, `134` started, `137` stopped, `139`/`142` AV detection). Zero
protocol lines. No `CTransport+::`, no `DispatchEvent`, no heartbeat text
anywhere in the log. No file was written under `C:\Program Files\EMC` in the
same window, no `.log` exists anywhere in the CEE tree, and no EMC-specific
event channel is registered.

So `Debug`/`Verbose` on Windows have no observable effect, and the wire is the
only instrument. That is not purely a loss: the first bring-up established that
the `status` attribute of CEE's reply *is* the `vcstatus` the array reports, so
a capture is closer to ground truth than a log line anyway.

### pktmon buffers until it is stopped

`pktmon` writes nothing readable to its `.etl` until `pktmon stop` flushes it.
A capture converted while still running reports `Packets total: 0` — including
for an exchange you just watched happen. Stopping the same capture and
converting the same file yielded 2340 packets.

This is worth stating because the failure mode is a false negative that reads
like evidence: "0 packets, nothing arrived" is exactly what a working capture
of a dead link looks like. Always validate a capture by generating known
traffic before trusting a zero, and remember the read cycle is
stop → `etl2pcap` → restart:

```powershell
pktmon filter remove
pktmon filter add CEPA -t TCP -p 12228
pktmon start --capture --pkt-size 0 -f C:\Windows\Temp\cepa.etl -s 256 -m multi-file
# … traffic …
pktmon stop
pktmon etl2pcap C:\Windows\Temp\cepa1.etl -o C:\Windows\Temp\cepa1.pcapng
```

`etl2pcapng` is not a subcommand despite what the output format is called; it
is `etl2pcap`, and it produces pcapng.

## PowerScale works, without CEE

OneFS pointed straight at cee-exporter delivers events end to end. All four
nodes complete the CEPA handshake (`body_bytes=233` in, `response_bytes=311`
out) and file events arrive as `action="11"` payloads carrying the full UNC
path, the acting NFS client address, and microsecond timestamps.

Two prerequisites that are easy to miss:

- **cee-exporter must be 5.4.0 or later.** 5.3.1 answers `CheckFileRequest`
  with an empty `200 OK` and logs `unrecognised CEPA payload`; OneFS treats the
  empty body as `STATUS_DATA_ERROR` and stops. The handshake landed after
  5.3.1 was cut.
- **`Protocol Auditing Enabled` must be `Yes` with an audited zone set.**
  Found disabled on this cluster with `Audited Zones: -`, in which case OneFS
  generates nothing to forward regardless of the CEE server URI, and the
  cursor in `isi audit progress global view` never moves.

### OneFS event types are fully resolved

`cepa-bring-up-findings.md` left `32`, `512` and `2048` unattributed, dividing
between rename, set_security and delete, because a single capture of a batched
`echo`/`mv`/`chmod`/`rm` sequence could not say which was which. An isolation
run — one operation per 10-second window — settled all three:

| eventType | Operation | Evidence |
|---|---|---|
| 8 | open/create | `touch`; carries `desiredAccess`, `createDispo` |
| 32 | **delete** | `rm` window, alone |
| 128 | close after writing | carries `bytesWritten`, `numberOfWrites` |
| 256 | ordinary close | same attributes, zeroed |
| 512 | **rename** | `mv` window, alone, emitted against the **source** path |
| 2048 | **set_security** | `chmod` window |

The attribution closes on itself rather than resting on the timing alone: `rm`
produced `32`, so `512` cannot be delete; `mv` produced only `512`, so `512` is
the rename. Implemented in cee-exporter `pkg/parser/onefs.go`.

## win25 does not meet the documented CEE requirements

Both gaps are real, neither is proven to matter for this deployment, and both
should be stated rather than discovered later.

- **Domain membership.** Dell: "The Windows network must contain a domain
  controller with both Active Directory and DNS enabled" (*CEE on Windows
  Platforms* 9.x rev 24, p7). On 2026-08-14 `win25` was `WORKGROUP` —
  `Win32_ComputerSystem.PartOfDomain` was `False`.

  > **No longer true. Re-measured 2026-08-22:** `PartOfDomain: True`,
  > `Domain: diab.local`, `DomainRole: 3` (member server), domain controller
  > reachable. The host was joined at some point after this document was
  > written, and the gap is closed.
  >
  > Worth noting how long this stale line survived: the *same section* of this
  > document records both CEE services running as `DIAB\Administrator`, which
  > is a domain account and cannot coexist with a workgroup host. The
  > contradiction sat in one file, unremarked, and was later cited as fact in
  > a diagnosis. **Re-measure host facts before building on them; a bring-up
  > document records one day, it does not describe the present.**
- **Service account.** The guide's "Complete the CEE installation for Windows
  Server" (pp11–12) makes it a required step to set the **EMC CAVA** service to
  log on as a domain account with rights to set up CAVA *and CEPA* server
  accounts, then reboot. Both `EMC Checker Server` and `EMC CEE Monitor` run as
  `LocalSystem` here. The step has never been performed, and cannot be on a
  workgroup host.

**Inference, not measurement:** the guide does not separate which CEPA paths
need the domain account. It describes remote consumer communication as
Microsoft RPC "in the same domain", and this deployment's consumer is reached
over HTTP instead — so the requirement may not bite. Nothing here has tested
it either way. Note that CEE's outbound leg to the HTTP consumer works fine as
LocalSystem on a workgroup host: `win25` has registered with cee-exporter every
10 seconds throughout.

## What the vendor guide confirms that was previously only measured

- **Endpoint order.** "CEE monitors the state of the first audit partner
  defined in the list to determine whether to publish events. If the first
  partner in the list is not available, events are also not published to
  subsequent partners" (p31).
- **Which service to restart.** "Any time you modify the CEE section of the
  Registry, except for Verbose and Debug, you must restart the EMC CAVA
  service" (pp21, 31). `cee_configure` restarts `EMC Checker Server`, whose
  display name is EMC CAVA — the right one, now confirmed by document as well
  as by measurement.
- **The AccessList takes FQDNs.** See `cepa-bring-up-findings.md`, which this
  closed.
- **CEPA pool counts.** One pool for pre-events; up to three for post-events
  and post-error events (p8).

The guide documents the endpoint as `<vendor>@<IPaddr>` — the RPC form — and
never mentions the `name@http://host:port` form this repo uses. That form is
what works against a HTTP consumer and is confirmed continuously in practice,
so the repo's documented format stands on measurement where the guide is
silent, not against it.

## PowerStore: the silence is CEE refusing, and it is now measured

This section replaces an earlier draft that called PowerStore's silence a
regression caused by repointing it at win25. That was wrong: the
`0x01301b03 all publishing pools unavailable` alert is timestamped
**2026-08-12 21:56**, two days before win25 existed in the loop.

### Root cause of the two-day outage: the wrong HTTP port

The Events Publisher had an HTTP port that did not match CEE's listener, so
NAS01 never opened a connection to 12228 at all. Every packet capture on win25
was empty — not rejected connections, not failed handshakes, *nothing* from
10.26.1.224.

Worth recording because of how badly it misleads: an empty capture looks
identical whatever the cause. Three hypotheses were argued from it in sequence
— pre-events, Microsoft RPC selected instead of HTTP, and an unbound publisher
— and all three were wrong. **Absence does not discriminate.** Fixing the port
produced heartbeats within seconds.

### What CEE actually answers: `CEPP_NOT_FOUND`

With the port corrected, NAS01 heartbeats cleanly and CEE replies `HTTP/1.1
200 OK` every time. Inside that 200:

```xml
<CheckFileResponse status="0x16" ceeVersion="9.3.0.0">
```

`0x16` is `VC_ERROR_CEPP_NOT_FOUND`. CEE accepts the connection, parses the
request, and tells the array it has no CEPP configuration for it — on every
heartbeat, 160 of 160 in one capture. It answers OneFS the same way.

**This is the explanation for the first bring-up's "connected, healthy,
silent".** The array was never going to publish.

### Measured: the array generates events and discards them

A single `touch` on an NFS export of a file system with Events Publishing
enabled produced, in the following heartbeats:

```
26 × preEventsMissed="0" postSuccessEventsMissed="0" postFailureEventsMissed="0"
 8 × preEventsMissed="0" postSuccessEventsMissed="2" postFailureEventsMissed="0"
```

Two post-success events generated, counted as **missed**, and **zero event
payloads on the wire** — only `action="9"` heartbeats, before and after. The
array knows no CEPP session exists and does not transmit.

That closes the causal chain end to end: CEE answers `CEPP_NOT_FOUND` → the
array does not publish → events are counted missed and dropped. No amount of
file activity changes it.

### What was eliminated

Each of these was tested against real array traffic and left `0x16` unchanged:

| Tested | Result |
|---|---|
| Endpoint `name@http://ip:port` vs `name@ip:port` | `0x16` both ways; CEE registers with the consumer under either |
| All 21 Pre-Events cleared from the pool | `0x16` |
| UNC-shaped vs bare cluster name (OneFS) | `0x16` both — retires the "Not UNC filename" theory |
| Registry configuration | Complete and correct; full `HKLM\SOFTWARE\EMC` dump reviewed |
| `Debug=1 Verbose=1` on **CEE and Monitor both** | No protocol output whatsoever |

One test did move the value, which proves CEE reads the configuration rather
than failing before it:

| `CEPP\Audit\Configuration\Enabled` | CEE answers |
|---|---|
| `1` | `0x16` — CEPP_NOT_FOUND |
| `0` | `0x1` — SETUP error |

### The unexplored lead: CHECK$

Every CEPA heartbeat names one resource — `\\nas01.diab.local\CHECK$`,
base64 UTF-16LE in `Args/@name`. From win25:

| Account | Result |
|---|---|
| `win25\administrator` (local) | error 1385 — logon type not granted |
| `DIAB\Administrator` (what CEE runs as) | **error 5 — access denied** |

TCP 445 to NAS01 is reachable, so the domain account authenticates and is then
refused. That is the signature of the missing **EMC virus-checking right**,
which the guide grants via a local group on the NAS server (chapter 5), and
which this deployment has never configured.

**Inference, not measurement, and it may be a coincidence.** The first
bring-up captured `CTransport+::GetServerName(): Isilon BAD CEPP_HEARTBEAT
request (Not UNC filename)`, which shows CEE *string-parses* that attribute to
extract a server name. If it only parses it and never opens the share, CHECK$
permissions are irrelevant to CEPA and this lead is noise. Windows CEE emits
no diagnostics, so the two readings cannot be separated from the host.

Against dismissing it: CEE's naming is systematically misleading here. The
service that owns the CEPA listener is `EMC Checker Server`, display name
"EMC CAVA". The install-completion step says the account needs rights to set
up "CAVA **and CEPA** server accounts". The antivirus-sounding components are
the CEPA components, so an antivirus-sounding right may well be a CEPA
prerequisite.

### PowerStore's CEPA dialect differs from OneFS's

Both were captured on the wire; a consumer must handle them separately.

| | PowerStore | OneFS |
|---|---|---|
| Method and path | `POST /vee` | `PUT /` |
| Encoding | UTF-16LE | UTF-8 |
| User-Agent | `EMC Data Mover` | none |
| Heartbeat body | `CheckFileRequest` + `CEPPHeartBeatArgs` | `CheckFileRequest` + `Args action="9"` |
| Reply encoding | UTF-16LE | UTF-8 |

The `/vee` path is what CEE serves; see the corrected OneFS section above.

The heartbeat also settles the access-list question conclusively — the array
announces its own identity in every one:

```xml
<CIFSServer netbios="NAS01" domain="DIAB" fqdn="nas01.diab.local" realm="DIAB.LOCAL">
```

`fqdn="nas01.diab.local"` is exactly what `cee_access_list` needs, and
`netbios="NAS01"` is the string CEE printed when refusing an address-based
list. That entry is no longer an inference.

### PowerStore requires Microsoft RPC, so CEE cannot be bypassed

The obvious escape from `CEPP_NOT_FOUND` was the one that worked for
PowerScale: point the array's CEPA pool straight at cee-exporter, which answers
`status="0x0"`. **That is not possible for PowerStore on this PowerStoreOS
version.**

The Events Publisher's transport selection — "Connect to CEPA servers via the
following protocols" — offers HTTP and Microsoft RPC. **Microsoft RPC cannot be
unticked**, neither on the existing publisher nor on a newly created one. It is
mandatory.

The consequence was measured before the cause was known, which is worth
recording because the symptom is so unhelpful. With the pool set to two servers
in this order:

```xml
<CEPPServerList>
  <CEPPServer ip="10.26.1.221"/>   <!-- first: cee-exporter, a Linux host -->
  <CEPPServer ip="10.26.1.199"/>   <!-- second: win25, Windows + CEE -->
</CEPPServerList>
```

the array **skipped the first entry entirely and used the second**. The
consumer's logs show it never received a single connection from the array — not
a failed handshake, not a rejected payload, nothing. A Linux host serves no
Microsoft RPC, so the array disqualifies it before opening a TCP session, then
falls through to the Windows host that does.

Two dead ends were eliminated on the way, both worth knowing:

- **DNS.** The consumer host had no A or PTR record in the array's zone, while
  both CEE hosts the array had ever used did. Records were created and the
  behaviour did not change. OneFS, for its part, publishes to that same host
  with no DNS record at all — so this is not a CEPA-wide requirement.
- **Ordering.** Confirmed from the array's own heartbeat rather than the UI:
  the list is transmitted in the configured order, and the array still skipped
  the first entry. It is not an ordering bug.

So a **Linux consumer can never be a direct CEPA target for this array**. That
is architectural, not configuration. Any consumer replacing CEE for PowerStore
would have to run on Windows and serve Microsoft RPC.

### Where it was left, and why that reading was wrong

This section originally concluded: "CEE answers `CEPP_NOT_FOUND`, CEE cannot be
bypassed, and escalation to Dell was ruled out. That leaves exactly one lever:
the authorization CEE lacks on the NAS server." The `CHECK$` access-denied
result was read as the missing **EMC virus-checking right**, made to look
stronger by the mandatory-RPC finding — the whole PowerStore↔CEE path is
Windows-authenticated, so an authorization gap seemed to fit.

It does not fit, and the reasoning is worth keeping because it is a good
example of a plausible lead crowding out an unexamined assumption. CEE never
reaches the point of needing any authorization on the NAS server: it refuses
the array before that, because it has no registered consumer to hand the events
to. See the next section.

The two documented gaps against the vendor guide — workgroup membership and the
service account — remain real and remain unaddressed. They are simply not what
produced `0x16`. Granting the EMC virus-checking right (PowerStore side: NAS01 →
Security & Events → Antivirus, or the Dell NAS Management snap-in, which is
**not** installed on win25) is still worth doing before calling the deployment
finished; it is no longer the blocking item.

## What CEE requires of an HTTP consumer

*(This section was titled "Why CEE answered CEPP_NOT_FOUND". It is not why —
see `cepa-2026-08-22-powerstore-session.md`. What it establishes about the
consumer contract is still correct and still worth honouring; the causal claim
was wrong.)*

Found 2026-08-21, from the vendored CEE 9.2.0.0 rpm rather than from the wire.
The Windows build writes no log at all and Dell publishes no protocol
specification, so `bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm` is the only readable
description of the CEPA consumer contract available. Its `.so` files and the
Windows DLLs are built from one source.

**`cee-exporter` answered CEE's registration with an empty body, so CEE never
registered it.** From `CEndPoint::Init()` in `libCEPPFilter.so`:

```
Top node is not RegisterResponse. Fail: %d.
Incomplete XML. Required Name or FriendlyName not present
Incomplete XML. Required description not present
Guid or FriendlyName not specified.
```

CEE parses the consumer's reply into a `CRegisterResponse` object and takes
from it the partner identity and the per-protocol event filter. An empty body
has no root element, so the parse fails every time. This document previously read the 10-second `<RegisterRequest />` cadence as a
keepalive; the first draft of this section read it as the opposite, a handshake
retried because it never completed. **Both readings are wrong — see "The
re-registration cadence is not a signal" below.**

The required shape is CEE's own, the literal it carries for its built-in
SplunkHEC proxy (`libCEPPAPIWrapper.so`):

```xml
<RegisterResponse>   <EndPoint friendlyName="SplunkHEC"
  guid="0fce0c69-ef49-4362-bae9-180ef0bf97c2" version="1.0"
  desc="Dell EMC SplunkHEC Proxy" />    <Filter protocol="0,1">
  <EventTypeFilter value="0xFFFFFFFF0000000000000000" />
  </Filter></RegisterResponse>
```

Protocol codes come from CEE's `ProtocolDesc` table: **0=CIFS, 1=NFS, 2=FTP,
3=Unknown**. The `EventTypeFilter` value is 24 hex digits — three 32-bit words,
one per event phase (pre, post-success, post-failure), matching
`CEPPEventTable`'s 28 slots × 3 flags. Which word is which phase is **not**
established; registering with every bit set sidesteps it.

A chain was drawn from this to the array's `0x16`. **It does not hold** — the
control on 2026-08-22 (dead endpoint, identical `0x16`) breaks the second link.
Fixing the registration is necessary for a consumer to ever receive events; it
is not sufficient, and it was not this fault.

Note the corroboration in Dell KB 000052027, *"CEE is not working due to CEPP
Server state ERROR_CEPP_NOT_FOUND"* — the same state, named as a CEE-side
condition rather than an array one.

### What this retires

- ~~The `CHECK$` lead.~~ **Wrong, and reinstated.** With every other candidate
  eliminated on 2026-08-22, `CHECK$` is the lead still standing.
- "Whether this is a 9.3 regression." It is not version-specific: 9.2 on SLES
  answered the same way, for the same reason.
- The theory that the array's silence was array-side event generation
  (`cepa-bring-up-findings.md`, "That leaves event generation on the array. It
  is a Dell support case"). The array generates the events correctly and
  discards them because CEE told it there was nowhere to send them.

### What it does not establish

The fix is implemented in `cee-exporter` and unit-tested, **but no array has
confirmed it.** The strings are from 9.2.0.0 while win25 runs 9.3.0.0; the
`CRegisterResponse` contract is very unlikely to have changed, but that is an
inference. Confirm in this order, each a distinct observable:

1. **The array's heartbeat reply turns `0x16` → `0x0`.** This is the only
   discriminator known to work, and it needs PowerStore heartbeating win25
   again — nothing is currently connected to 12228, measured with
   `Get-NetTCPConnection -LocalPort 12228`, which shows the listener and no
   peer.
2. A `touch` on an Events-Publishing-enabled export then produces a
   `<CheckEventRequest>` on the wire. Confirm the file was actually created
   before trusting a negative.
3. Then re-arm `cee_access_list_enabled: 1` (contents are already correct) and
   set `cee_debug`/`cee_verbose` back to `0`.

Two checks that look obvious and do **not** work are recorded in the next two
sections, so nobody spends an afternoon on them.

### The re-registration cadence is not a signal

**Measured 2026-08-21, and it retires the check this section originally
proposed.** Three identical CEE 9.2.0.0 instances were pointed at three mock
consumers differing only in what they returned to `<RegisterRequest />`:

| Consumer reply | CEE's behaviour |
|---|---|
| A valid `<RegisterResponse>` | `PUT /` `<RegisterRequest />` every 10 s |
| An empty body | `PUT /` `<RegisterRequest />` every 10 s |
| Malformed, non-XML garbage | `PUT /` `<RegisterRequest />` every 10 s |

Identical in all three. CEE never sent `<HeartBeatRequest />`, never changed
cadence, never gave up. So "CEE keeps re-registering" says nothing at all about
whether the registration was accepted — it is simply what CEE does over HTTP,
plausibly because the transport is stateless and it re-registers each cycle.

This cuts both ways and should be stated as such: it removes the evidence that
the empty body was *failing*, while leaving the evidence that an empty body
*cannot* satisfy `CEndPoint::Init()` untouched, because that comes from the
code rather than from behaviour.

### CEE logs nothing about its consumer leg, even at Debug=1 Verbose=1

Also measured 2026-08-21, against CEE 9.2.0.0 on Linux, where the first
bring-up established that `Debug`/`Verbose` are what make CEE speak at all.
They do not extend to this leg. With both set to 1 and the banner confirming
`Verbose : 1` / `Debug : 1`, CEE printed its startup banner, then
`CLinuxCore::Run(): Running service`, then **nothing** — while demonstrably
PUTting a registration every 10 seconds and answering inbound heartbeats. No
`CEndPoint::Init()` line, no `CTransport+::` line, `/opt/CEEPack/logs/` empty.

So the plan of "debug it on Linux where CEE talks, then apply to Windows" does
not work for this question. Linux CEE is as silent as Windows CEE here.

One practical trap found on the way: CEE's stdout is block-buffered when it is
a pipe, so `docker run -d` without a TTY shows an empty `docker logs` until the
process exits. Run it with `-it`, or conclude nothing from the silence.

### Replaying a captured heartbeat does not reach the CEPP lookup

The obvious way to get the `0x16`/`0x0` answer without an array is to replay
NAS01's captured heartbeat at CEE directly. It does not work: every replay is
answered `status="0x10"`, which `libSourceAPIWrapper.so` names
`VC_ERROR_BAD_REQUEST` (*"evtcxt init failed"*). CEE rejects the request before
it ever looks for a CEPP configuration, so the reply is the same whether a
consumer is registered or not.

Varying `celerraIP` to match the real source address changed nothing. This is
the same trap this document already records for the OneFS replay, and it has
now cost two attempts: **a replayed CEPA request is not a substitute for array
traffic.**

## State left behind

`ansible/group_vars/all.yml` is gitignored, so these are local to this
deployment:

- `cee_access_list` now holds `nas01.diab.local` plus the four PowerScale node
  addresses — correct contents per the vendor guide — but
  `cee_access_list_enabled` is still `0` pending PowerStore publishing again.
- `cee_debug: 1`, `cee_verbose: 1` remain set. They cost nothing on Windows
  because they do nothing there, but they are still diagnostic-only on Linux.
- `group_vars/cee_windows.yml` pins `cee_windows_version: 9.3.0.0` and its
  ProductCode. `bin/` vendors no 9.3.0.0 installer — Dell ships it only through
  their authenticated portal — so `cee_install` finds the release already
  registered and skips staging.
- The test stack's `cee-exporter` runs a locally-built image, not a published
  tag, because the OneFS `action="11"` parser and the PowerStore POST/UTF-16
  support are not yet released. It is published on **12228 as well as 12229**
  via `docker-compose.ports.yml`, so an array can be pointed at it on the CEPA
  default port. That file is deliberately not named
  `docker-compose.override.yml`, which would auto-load against
  `docker-compose.yml` — where those services do not exist — on every
  `docker compose` call in the directory.
- `HKLM:\SOFTWARE\EMC\CEE\Monitor\Configuration` has `Debug`/`Verbose` set to
  1. They produce nothing; they were set to prove that and never reverted.
- Both CEE services on win25 run as `DIAB\Administrator`. That is a domain
  admin, which is more privilege than CEE needs — the guide wants a
  purpose-made service account. `cee_configure` can now set one via
  `cee_windows_service_account`, but this host was configured by hand and the
  variables are not set.
- **`EMC CEE Monitor` does not auto-start after a reboot**, exiting 1077
  (`ERROR_SERVICE_NEVER_STARTED`, i.e. no start was attempted) despite
  `StartMode=Auto`. It starts manually without complaint. `EMC Checker
  Server`, which owns the listener, is unaffected — so this is not currently
  load-bearing, but a rebooted host is left with one CEE service down and
  nothing says so.
- Grafana: `cee-exporter` is wired into the **existing** `pscale_exporter`
  monitoring stack rather than the test stack's own — a scrape job on
  `10.26.1.221:9228`, a second datasource registration under the uid the board
  hard-codes, and the dashboard filed under a `CEE` folder. Note that
  `prometheus.yml` is a single-file bind mount there: editing it replaces the
  inode, so a SIGHUP reload reports success while the container keeps serving
  the old file. It needs a container restart.
