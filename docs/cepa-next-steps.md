# CEPA — handover, 2026-08-22

Working document. Delete it when the open items are closed; the durable
knowledge is already in `cepa-protocol.md` and `cee-partner-allowlist.md`.

## State of play

**PowerStore event publishing works end to end for the first time.** SMB
activity on NAS01 → CEE 9.3.0.0 on win25 → cee-exporter → binary `.evtx`, read
back by `Get-WinEvent` on Windows Server 2025 (25 records, EventID 4663,
Provider `PowerStore-CEPA`).

The blocker was never the array. CEE refuses to register a consumer whose
identity is not in `CGuidStore`, a table compiled into `libCEPPAPIWrapper.so`;
with no registered partner it answers every array heartbeat `0x16
CEPP_NOT_FOUND` and the array silently discards its events. Read
`cepa-protocol.md` before touching anything.

## The configuration that works

```toml
# cee-exporter-config.toml (tracked — this is the repo's test-stack config)
[cepa]
friendly_name = "PeerSoftwareCollector"
guid          = "49f4da0f-055f-401c-9f83-a95ce61447f6"
event_filter  = "0xFFFFFFFF0000000000000000"
```

```
# win25: HKLM\SOFTWARE\EMC\CEE\CEPP\Audit\Configuration
EndPoint = PeerSoftwareCollector@http://10.26.1.221:12229
```

The two names must match, and the GUID must be that name's pairing for the
**Audit** facility. `PeerSoftwareCollector` is Peer Software's registered
identity — see the caveat in `cee-partner-allowlist.md` before shipping this.

**In Ansible, and now guarded.** The endpoint name above was originally set by
hand via `win_regedit`, and `ansible/group_vars/all.yml` is gitignored, so
re-running `site.yml` with the old `cee_endpoints[0].name: ceeexporter` used to
break it again silently. `cee_common/tasks/assert_partner_identity.yml` now
rejects any name outside CEE's Audit allowlist before the play touches a host,
so that re-run fails loudly instead. See open item 3.

## Environment

| host | role |
|---|---|
| `epg` 10.26.1.221 | this workstation; runs cee-exporter (12229, and 12228 for OneFS) |
| `win25.diab.local` 10.26.1.199 | CEE 9.3.0.0, domain-joined, services as `cee@diab.local` |
| `nas01.diab.local` 10.26.1.224 | PowerStore NAS server, SMB share `SMB01` on `/FS01` |
| `diabps01` 10.26.1.20 | array management / REST API |
| 10.26.1.150–.153 | PowerScale, publishes straight to cee-exporter, unaffected |
| 10.26.1.225 | **an undocumented CEE 9.2.0.0** that registers with our consumer every 10 s. Nobody has identified it. |

Array API credentials live in `/home/fjacquet/pstore_exporter/.env`
(`PSTORE1_USERNAME`/`PSTORE1_PASSWORD`; its `PSTORE1_HOSTNAME` is a
placeholder — the real array is `10.26.1.20`). That account is **read-only**:
`PATCH` returns 403, so array changes need the UI or an admin credential.

## Commits — none pushed

```
cee-worker    (docs/cepa-bring-up-findings)
  98fd957  docs(cepa): add the protocol reference, and make the runbook actually work
  977ed0c  docs: retire the "no array has ever been in the loop" caveats
  046fc4e  docs(cepa): CEPP_NOT_FOUND solved — CEE's compiled-in partner allowlist

cee-exporter  (feat/onefs-cepa-handshake)
  8457523  docs: ADR-017, the operator-guide gap, and CEPA-06..09
  9070c5d  refactor(cepa): decode the body once, and share the reply path
  27a980d  docs: correct CEPA-01, which stated the inverse of the truth
  044264a  docs: the [cepa] identity block is required for Dell CEE
  309d277  feat(cepa): register with CEE and parse its events, end to end
```

`9070c5d` is worth knowing about before you build on the parser: every
`parser.Is*` predicate transcodes the whole body, so dispatching through four
of them plus parsing decoded a UTF-16 payload five times per request — 62% of
the time and 92% of the allocations on a 1000-event batch. `parser.Classify`
now decodes once; the exported API is unchanged via wrappers. Prefer it over
the individual predicates in any new dispatch code.

Verified locally before handover: `go build`, `go vet`, `go test -race`
(8 packages), `gofmt`, `golangci-lint` (0 issues), `go mod tidy -diff`, all four
`docs-lint` guards, `ansible-playbook --syntax-check site.yml`, and
`ansible/tests/run.sh` (`ok=13 failed=0`).

*Superseded 2026-08-22.* That paragraph described the doc-only commits above,
and said `yamllint` / `ansible-lint` were unavailable on the machine of the day.
Both statements are now stale: later work on this branch adds a `cee_common`
gate, a test playbook and workflow changes, so `ansible/` and `.github/` YAML
**are** touched — and both linters were run on the dev station, clean
(`ansible-lint` production profile, `yamllint` with only the pre-existing
`document-start` warning in `publish.yml`), alongside `ansible/tests/run.sh`
and `ansible-playbook --syntax-check site.yml`.

## Open items, in priority order

### 1. Resolve the twenty unmeasured event codes — DONE, and no capture needed

Resolved by reading `GetEventDescr8(CEPP_EventType)` out of `libConvert.so` in
the vendored rpm. The full table is now in `cepa-protocol.md` under "Events",
with the command to reproduce it. **No array, no SMB client, no host.**

Outcome: **19 bits, mask `0x7FFFF`**, not 21 / `0x1FFFFF`. Dell's documented
ordering was right for all nineteen; its last two names
(`OpenFileReadOffline`, `OpenFileWriteOffline`) do not exist in CEE 9.2.0.0.
Bit 3 = `FileCreate`, matching the one bit that had been confirmed by capture —
which is the check on the method.

Still open, and it is the small half: **carry the table into
`pkg/parser/checkevent.go`** in cee-exporter, drop bits 19–20, and take the
"provisional" markers off. Use CEE's own spellings (`FileCreate`, not
`CreateFile`) or note the mapping where they diverge.

The staged capture on `\\nas01.diab.local\SMB01` is no longer needed to *derive*
the codes. It would still be worth one pass as confirmation if a client that can
reach the share turns up — win25 **cannot** (checked).

### 2. Understand the `0x1` on event deliveries

CEE answers heartbeats (`action="9"`) `0x0` but events (`action="11"`) `0x1
VC_ERROR_SETUP`. Nothing is lost — `postSuccessEventsMissed` stays 0 and every
event reaches the consumer — but it is not understood and should be before this
is called production. Reproduce with `cepa_probe.sh 40`.

### 3. Get the identity into Ansible — DONE

`cee_configure` writes `EndPoint` from `cee_endpoints[].name`.

- `all.yml.example` ships `name: PeerSoftwareCollector` and explains that the
  name is not free-form.
- **The gate exists**: `cee_common/tasks/assert_partner_identity.yml` rejects
  any endpoint name outside the 27 identities CEE registers for Audit, named
  in the failure message, with the `0x16` consequence spelled out. It runs last
  in `cee_common`, after `assert_facilities` has established that Audit is the
  enabled sub-facility — which is what makes checking only the Audit half
  correct. The 27 names were re-derived from `CGuidStore::Init()` in
  `libCEPPAPIWrapper.so` for this purpose, not copied from the doc; all 47
  (name, facility) pairs matched it exactly.
- `ansible/tests/test_partner_identity.yml` covers an invented name
  (`ceeexporter`, the one that actually shipped), a case-only difference, a
  name valid for a different facility, one bad name hidden among good ones,
  and the `cee_partner_allowlist_extra` escape hatch. Mutation-tested: with
  the assertion disabled, all four negative plays fail.
- `ansible/group_vars/all.yml` on **this** controller still said `ceeexporter`
  and has been corrected. It is gitignored, so **every other controller must be
  fixed by hand** — and now fails loudly instead of silently if it is not.

Escape hatch: `cee_partner_allowlist_extra` (default `[]`) exists only for an
identity added in a CEE release newer than the vendored 9.2.0.0. It cannot make
an invented name work; it only moves the failure back to being silent.

### 4. Re-arm the access list

`cee_access_list_enabled` is still `0`. Contents are already correct
(`nas01.diab.local` plus the four PowerScale node addresses). Set it to `1` —
documented as the last step of the bring-up, not optional.

### 5. Reset diagnostics

`cee_debug` / `cee_verbose` are `1` in `group_vars/all.yml`; win25's registry is
back to `1`. Set both to `0` for steady state. (`Debug=63` being the level that
explains a refusal is now recorded in the runbook's troubleshooting section and
in `cepa-protocol.md`.)

### 6. Housekeeping

- `EMC CEE Monitor` on win25 does not auto-start after a reboot (exit 1077) and
  now also fails to start manually under `cee@diab.local`. Not load-bearing —
  `EMC Checker Server` owns the listener — but a rebooted host is left with one
  service down and nothing says so.
- Identify 10.26.1.225.
- `docs/acceptance-tests.md` AT-8…AT-14 are not marked passed. The path they
  cover is proven; their individual procedures have not been re-walked.

## Leave-behind on this machine

Tear these down when convenient — none is load-bearing:

```bash
docker rm -f cee_live                       # CEE 9.2 debug rig on :12230
fuser -k 12240/tcp                          # the registration mock
```

`test_cee_exporter` **must stay up** — it is serving PowerScale as well as
PowerStore.

`state/cepa-evidence-2026-08-22/` (gitignored, does not travel via git) holds the
packet captures, the registry dump, `nas01-session-verbatim.bin`, `cepa_probe.sh`
and `dbgcapture.ps1`. Copy it by hand if you want the offline reproduction:
replay that file at a CEE 9.2 container and the `0x16` reproduces with no array.

## Two traps that cost days

- **A dead endpoint and a rejected registration are indistinguishable** — both
  give the array `0x16`. Do not read "same result with a dead endpoint" as
  "the consumer leg is innocent". That inference cost a full day.
- **`Debug`/`Verbose` are a 6-bit mask, not a scale.** `1` says nothing, `9`
  says less than `3`, `63` names the reason. Three bring-ups concluded "CEE
  tells you nothing" on the strength of `Debug=1`.
