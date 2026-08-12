# CEPA bring-up — measured findings

First bring-up of the Ansible-deployed CEE against real arrays, 2026-08-12,
from `epg` (10.26.1.221) driving `cee-sles01` (10.26.1.222, SLES 15 SP7,
CEE 9.2.0.0). Two arrays were in the loop: PowerStore `diabps01` (NAS server
NAS01, 10.26.1.224) and a 4-node PowerScale `powerscale1` (OneFS 9.13.0.0,
nodes 10.26.1.150–.153).

Everything below was measured on those hosts — tcpdump on the wire, CEE's own
debug journal, `isi_audit_viewer` on the cluster. Where a claim is an
inference rather than a measurement it says so.

**Outcome: Stage 3 of `powerstore-setup-runbook.md` is still unproven.** No
array-originated event has ever reached the consumer. What changed is that the
failure is now localised: every leg this repo controls is verified working, and
the remaining fault is array-side event *generation*, which is a Dell support
matter. Stages 1 and 2 pass.

## The access list rejects every array when it holds IP addresses

The single highest-impact finding, because this repo ships
`cee_access_list_enabled: 1` by default and `group_vars/all.yml.example`
describes that as "the vendor default and the right posture on a real
network".

With `AccessListEnabled=1` and an `AccessList` of IP addresses, CEE rejects
the CEPA heartbeat of both array families before doing anything else:

    CTransport+::ValidateArgs(): PowerStore BAD CEPP_HEARTBEAT request (server [NAS01] event not allowed)
    CTransport+::ValidateArgs(): Isilon BAD CEPP_HEARTBEAT request (server [] event not allowed)

Note what CEE names: the **server name** (`NAS01`), not the source address.
The list held `10.26.1.224`, the address that heartbeat came from, and it was
still refused. The array sees this as a setup failure and never publishes —
OneFS logs `vcstatus 0x1: VC_ERROR_SETUP`, PowerStore raises
`0x01301b03 all publishing pools unavailable`.

Setting `cee_access_list_enabled: 0` removed the rejection immediately and
both arrays' heartbeats began dispatching cleanly. Peer Software's PowerStore
guide — written against PowerStoreOS 4.1 and CEE 9.2, this repo's exact
versions — independently lists `AccessListEnabled ≠ 0` as one of three causes
of "pool reachable but zero events", alongside `ServerEnabled ≠ 1` and a
blocked inbound 12228.

**Not yet established:** whether populating the list with NAS *server names*
rather than addresses makes it work. That is the obvious next experiment and
it was not run. Until someone runs it, treat `AccessListEnabled=1` as
incompatible with an address-based list, and understand that turning it off
removes a real access control — CEE will accept CEPA posts from anything that
can reach 12228, so the firewall becomes the only gate.

## CEE 9.2.0.0 logs nothing at all unless Debug and Verbose are on

`CLAUDE.md` says CEE logs to stdout and systemd captures it into the journal.
True, but incomplete in a way that costs hours: at the shipped
`Debug=0`/`Verbose=0`, CEE writes **nothing** to the journal — not even for a
*successful* exchange.

Measured directly: a PowerScale heartbeat was captured on the wire at
08:34:06 completing normally (`HTTP/1.1 200 OK`, a well-formed
`CheckFileResponse`), and `journalctl -u emc_cee` across that exact window
returned `-- No entries --`.

So an empty journal is not evidence that nothing arrived, and
`powerstore-setup-runbook.md`'s diagnosis step 3 — "a rejected source is
logged there; a firewalled one leaves no trace" — only holds with debug
enabled. Set `cee_debug: 1` and `cee_verbose: 1` *before* concluding anything
from journal silence. Every root cause in this document came from that switch;
none was visible without it.

## PowerStore: connected, healthy, and silent

After the access list was disabled, PowerStore reached a state where every
observable is green and no events are produced:

- heartbeats dispatched cleanly every 10s, `CTransport+::DispatchEvent():
  PowerStore CEPP_HEARTBEAT request`, no errors
- filtering the journal for anything that is *not* a heartbeat returns nothing
  whatsoever — CEE receives only heartbeats, never an event
- zero alerts on NAS01; Events Publishing enabled on the NAS server; enabled
  on file system FS01 with NFS selected; all Post-Events checked in the pool;
  Post-Events Failure Policy set to `Accumulate`
- `cee_events_received_total` never moves

Eliminated by measurement, each with its own test:

| Suspected cause | How it was ruled out |
|---|---|
| NFS protocol version | Tested at `vers=4.2` and `vers=3`; identical silence |
| Stale NFS session predating the config changes | Unmounted and remounted, then created, wrote and deleted; identical silence |
| Wrong event type selected | All Post-Events checked, not just `CreateFile`/`DeleteFile` |
| DNS | `cee-sles01.diab.local` A and PTR records created on 10.26.1.50, NAS01's own DNS repaired, all NAS01 alerts cleared |
| CEE unreachable / firewalled | Heartbeats arrive and are answered |
| Consumer broken | Stage 2 passes; CEE→cee-exporter registration heartbeat runs continuously |

That leaves event generation on the array. It is a Dell support case, and the
evidence above is what to hand them.

### Verify the test actually wrote something

Several early "tests" were silent no-ops. `/ifs/test` was mode `700` owned by
`admin`, and the PowerStore export root was root-owned `755`, so `touch`
returned `Permission denied` — but the failure scrolled past in a compound
command and the run looked like it had happened. Hours of "no events" were
measuring nothing at all.

Confirm the file exists before believing a negative result. On PowerScale the
give-away was `Protocol Audit Log Time` not advancing; on PowerStore it was
the export directory's mtime. Use a world-writable subdirectory created once
(`/test2/ceetest`), not `sudo` against a root-squashed export.

## PowerScale is not usable with this CEE build

OneFS generates the events correctly — `isi_audit_viewer -t protocol` shows
the exact test filenames with `eventType: create` / `delete`, `protocol:
NFS4`, and the right client address — but `Protocol Audit Cee Time` never
advances past the moment the CEE server was added. Nothing is ever forwarded.

CEE cannot derive a server name from OneFS's request:

    CTransport+::GetServerName(): Isilon BAD CEPP_HEARTBEAT request (Not UNC filename)

The name arrives as base64 UTF-16LE (`powerscale1`) inside
`<Args … name="…"><Cluster …/></Args>`, and CEE wants something UNC-shaped.
With an empty name it finds no CEPP configuration to apply and answers
`VC_ERROR_CEPP_NOT_FOUND` (`vcstatus 0x16`). Setting OneFS `--hostname` to the
FQDN and pointing it at CEE by FQDN changed nothing.

**Inference, not measurement:** this looks like a CEE-side parsing limitation
rather than a misconfiguration, but it was not confirmed with Dell. PowerScale
was only ever a stand-in while PowerStore's network fault was under ticket;
it is out of this repo's scope.

Note for cluster deployments if it is ever revisited: every node runs its own
`isi_audit_cee` and publishes independently. All four node addresses appeared
as separate peers at the consumer, so an access list — or any per-source
configuration — must list every node, not just the one you happen to SSH into.

## cee-exporter cannot serve OneFS directly

Bypassing CEE and pointing OneFS straight at cee-exporter 5.3.1 does not work.
OneFS opens with `CheckFileRequest`; `pkg/server` recognises only
`RegisterRequest` and falls through to the event parser, which rejects it:

    level=ERROR msg=cepa_parse_error error="unrecognised CEPA payload: \"<CheckFileRequest><Args action=\\\"9\\\" …"

OneFS then fails on the empty reply — `Error while parsing CEE
CheckFileResponse` → `STATUS_DATA_ERROR`. This closes one of the open
questions in that repo's own `docs/powerscale-verification.md` ("Whether OneFS
performs the CEPA `RegisterRequest` handshake" — it does not; it sends
`CheckFileRequest`) and belongs upstream as an issue.

### What OneFS sends, and what it expects back

OneFS opens with this, 229 bytes, plain UTF-8 — note that it is a different
dialect from the 38-byte UTF-16LE `<RegisterRequest/>` that PowerStore's CEE
sends, which is why `IsRegisterRequest` does not match it:

    <CheckFileRequest><Args action="9" sourceIP="10.26.1.150" sourceID="2"
      name="cABvAHcAZQByAHMAYwBhAGwAZQAxAA=="><Cluster
      id="00505692f33595217c6ab005f128c9b4c9f9"
      name="cABvAHcAZQByAHMAYwBhAGwAZQAxAA=="/></Args></CheckFileRequest>

`action="9"` is the heartbeat. `name` is the cluster name as base64 of
UTF-16LE (`powerscale1`).

**The `status` attribute of the reply is the `vcstatus` OneFS reports.**
Measured twice, on two different values, by capturing CEE's reply on the wire
and reading the cluster's log for the same exchange:

| CEE replies | OneFS logs |
|---|---|
| `status="0x1"` | `vcstatus 0x1: VC_ERROR_SETUP` |
| `status="0x16"` | `vcstatus 0x16: VC_ERROR_CEPP_NOT_FOUND` |

So the reply shape to implement is CEE's, with a success status:

    <CheckFileResponse status="0x0" ceeVersion="9.2.0.0">
    <HeartBeatResponse ceeVersion="9.2.0.0" dtdVersion="2.5.3">
    <CEPPHeartBeatResponse><CEPPCapabilities>
    <Protocols CIFS="1" NFS="1" HDFS="0"/><Partner multiplicity="1"/>
    </CEPPCapabilities></CEPPHeartBeatResponse></HeartBeatResponse></CheckFileResponse>

`0x0` is an **inference**, not a measurement: no successful OneFS handshake
has ever been observed, because CEE never gets that far with this cluster.
Both observed non-zero values map to errors and 0 is the conventional
success, but it must be confirmed by trying it.

### The handshake was implemented, and it works

`cee-exporter` was patched to answer `CheckFileRequest` with the response
above and tested against the live cluster. The result is unambiguous: all four
nodes heartbeat cleanly, and `Protocol Audit Cee Time` — stuck at 08:17:33 for
the entire day — jumped to match `Protocol Audit Log Time` exactly. The
cluster drained its backlog the moment the handshake was accepted, which
settles `status="0x0"` as correct.

### OneFS carries events in the same element as the heartbeat

Measured immediately after, and it invalidates the obvious implementation.
Events are **not** a different element — they are `CheckFileRequest` with a
different `action`:

    <CheckFileRequest><Args action="11" sourceIP="10.26.1.150" sourceID="2"
      name="<base64 UTF-16LE UNC path>" protocol="1">
      <Cluster id="…" name="<base64>"/><Zone id="1" name="<base64 System>"/></Args>
      <NFSEventArgs eventType="8" desiredAccess="0x100106" createDispo="0x3"
        userSid="S-1-22-1-1000" clientIP="10.26.1.222" userId="1000"
        ntStatus="0x0" timeStamp="1786563708" timeStampMicroSeconds="859323"
        inode="4295432746" fsId="1"/></CheckFileRequest>

`action="9"` is the heartbeat, `action="11"` an NFS file event. `name` decodes
(base64 of UTF-16LE) to a full UNC path —
`\\powerscale1.diab.local\onefs$\ifs\test\evtest-….txt` — which is presumably
what CEE's `GetServerName()` wanted and did not get from the heartbeat.

Treating every `CheckFileRequest` as a heartbeat is therefore *worse* than
rejecting it: acknowledging an event advances the cluster's forwarding cursor,
so the record is consumed and gone. The exporter now inspects the action and
logs unhandled events at WARN with the full payload, so nothing is lost
invisibly while parsing is unfinished.

### Event types are numeric, not `CEPP_*`

This closes cee-exporter's biggest open question, and the answer is "neither
of the two candidates". `pkg/mapper` keys on the `CEPP_*` family; OneFS sends
an integer in `NFSEventArgs/@eventType`. Measured from one known sequence —
`echo > f`, `mv`, `chmod`, `rm`:

| eventType | Seen on | Distinguishing attributes |
|---|---|---|
| 8 | source file | `desiredAccess`, `createDispo` — an open/create |
| 128 | source file | `bytesWritten`, `numberOfWrites` — a close after writing |
| 256 | both files | same attributes — the ordinary close |
| 512 | source file | none |
| 32 | renamed file | none |
| 2048 | renamed file | none |

The values are powers of two, so this is a bitmask. `8` and the closes are
established. **`32`, `512` and `2048` are not**: they divide between rename,
set_security and delete, and a single capture of a batched sequence cannot say
which is which. Isolating one operation per capture is the remaining work —
guessing the mapping here would put wrong event IDs into an audit trail, which
is worse than not writing one.

## Array-side prerequisite this repo under-documents

`powerstore-setup-runbook.md` and `ansible-deployment.md` both say "SMB
configured on the NAS server; NFS optional" with no rationale. The real rule
is stronger and worth stating: **an NFS-only NAS server cannot have Events
Publishing enabled at all.** Dell KB 000060271 — *"It is not possible to
enable CEPA on NFS Only NAS Server… You must enable SMB on the NAS Server in
order to be able to configure CEPA, even though CEPA works for both NFS and
SMB."* The workaround is a **standalone** SMB server with no shares and no SMB
file systems; domain join is not required.

Consequence worth knowing before doing it: adding SMB alongside NFS turns the
NAS server multiprotocol, and Dell states DNS cannot be disabled on a
multiprotocol NAS server. Plan for working DNS on the array.

## State left behind

`ansible/group_vars/all.yml` is gitignored, so these are local to this
deployment and will not be obvious to anyone else:

- `cee_access_list_enabled: 0` — see the first section. Revisit with server
  names before turning it back on.
- `cee_debug: 1`, `cee_verbose: 1` — diagnostic only, not a steady-state
  setting. Set both back to 0 once the PowerStore case closes.
- `cee_access_list` lists all four PowerScale nodes alongside the PowerStore
  NAS server, which is correct regardless of whether the list is enabled.
