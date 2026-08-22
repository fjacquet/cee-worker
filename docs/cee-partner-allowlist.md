# CEE partner allowlist — the identities CEE will register

**This is the gate that blocked event publishing across three bring-ups.**

Dell CEE will not register a consumer whose identity it does not already know.
`CGuidStore` is a table compiled into `libCEPPAPIWrapper.so`, keyed by
**(friendlyName, facility)** and yielding a GUID. `CBaseClient::ValidateResponse()`
looks the pair up with `CGuidStore::FindPairedGuid()` and rejects anything else:

```text
Partner error, unknown or invalid GUID; Partner Provided FriendlyName: … Guid: …
Partner error. GUID mismatch;          Partner Provided FriendlyName: … Guid: …
```

A rejected registration means no partner, and CEE then answers every array
heartbeat `status="0x16"` (`VC_ERROR_CEPP_NOT_FOUND`). **A self-generated GUID can
never work.** Three things must agree:

1. the partner id in CEE's `EndPoint` value (`<name>@http://host:port`)
2. `friendlyName` in the consumer's `<RegisterResponse>`
3. `guid` in that same element — the table's pairing for that name *and facility*

Getting name and facility right but the GUID wrong gives `GUID mismatch`; an
unknown name gives `unknown or invalid GUID`. Registering successfully is still
not enough — CEE then probes with `<HeartBeatRequest />` and needs `hbStatus=0`,
or the partner stays `OFFLINE` and the array gets `0x12`.

## How this table was produced

Disassembled from the vendored CEE **9.2.0.0** rpm, which is the reference of
record for this repo (Dell publishes no specification). `CGuidStore::Init()` makes
47 `ValidateAndAdd(name, facility, guid)` calls; the name is the `%rsi` operand,
the facility the `%edx` immediate, and the GUID is pushed as three 8-byte pushes
from `m_Guids` whose offset is the last push's displacement.

The **facility numbers** below are those `%edx` immediates verbatim. Their
**names** come from a second place — `GetFacilityIDDescr(FacilityID)` in
`libConvert.so`, a dense jump table over 0–12 where every arm is a bare
`leaq <name>; retq`, so the mapping is unambiguous:

**0 CAVA, 1 CQM, 2 Audit, 3 Index, 4 CEMA, 5 Backup, 6 CARA, 11 VCAPS,
12 VCAPS+** (7–10 are `Unknown`).

*Corrected 2026-08-22.* This table previously labelled facility 1 as CAVA, 3 as
CQM and 6 as Index. The numbers were always right; the names were guessed. No
entry in CGuidStore uses facility 0, so **there are no CAVA partners here at
all** — the six rows now marked CQM were the ones mislabelled that way. Audit
(2), Backup (5) and VCAPS+ (12) were unaffected, which is why nothing
operational changed: the identity this deployment uses is Audit either way.

Independently validated: this decode yields `Varonis` →
`971fbab4-b5b2-4176-a945-186ab8e3491e`, exactly the GUID captured in Dell KB
000049515.

Verified end to end on 2026-08-22 against PowerStore `diabps01` / NAS01:
`PeerSoftwareCollector` + its Audit GUID took CEE from `0x16 CEPP_NOT_FOUND` to
`0x0 NORMAL`, and real SMB events reached the consumer.

## Caveat worth stating

These are other vendors' registered identities. There is no mechanism for a
third-party consumer to obtain its own entry short of Dell adding one to a future
CEE build. Using one of these makes CEE work; it also means CEE (and anyone
reading its logs) will report your consumer under that vendor's name, and it
would collide with a genuine deployment of that product on the same CEE host.
Choose deliberately.

## The table

| friendlyName | facility | GUID |
|---|---|---|
| `Northern` | 1 CQM | `d1891933-708b-4e3c-94c2-4cab729eb83c` |
| `NTP` | 1 CQM | `68065318-c819-42bb-84e5-ecd39641a0a7` |
| `Symantec` | 1 CQM | `5d4085be-4792-48f4-b1f4-48cd6eccd2cb` |
| `Axur` | 2 Audit | `03331fbe-6147-4ce1-8478-507ec8f65968` |
| `RSA` | 1 CQM | `6090807c-0d57-4dac-a479-732ad598cebb` |
| `Replistor` | 2 Audit | `7c80d9fc-dfbd-4775-bee0-3c20a3598c8d` |
| `Varonis` | 2 Audit | `971fbab4-b5b2-4176-a945-186ab8e3491e` |
| `Whitebox` | 2 Audit | `1423fb52-7c22-41b5-8c24-95398d174f5b` |
| `SymantecDataConnector` | 2 Audit | `b14c24e9-e9ef-4fdc-a164-13bb9c1d6646` |
| `ArcSightConnector` | 2 Audit | `5fb476ad-d0cd-4b74-bdce-48da73e533e3` |
| `QuestSoftware` | 2 Audit | `91d2b234-5551-4039-beee-10cb3cd0703b` |
| `SenSage` | 2 Audit | `d2084525-1e66-4066-bc1f-f43c33f89119` |
| `Aspera` | 2 Audit | `0357cd86-1965-4435-b1d8-42ac603665dd` |
| `CourionCollector` | 2 Audit | `f7d129ae-c760-48b0-a254-4a9ef425b2c0` |
| `StealthAUDIT` | 2 Audit | `dd51a7e5-63ab-4166-8aba-b300f4270d0d` |
| `Splunk` | 2 Audit | `8bff877d-39bd-4b56-80ce-8b7884711d3f` |
| `Likewise` | 2 Audit | `754d377a-57ee-42df-955c-9889e9fbc881` |
| `Nasuni` | 2 Audit | `5fb0515b-722d-4e8d-8061-4e1d07da2bea` |
| `Scania` | 2 Audit | `610cea68-c7e3-41f8-a6a4-c4a84876354b` |
| `egnyte` | 2 Audit | `633b9382-cc1a-4812-b091-257e59c91daf` |
| `USDCloud` | 2 Audit | `02d18515-92ee-45ac-8dfa-966c8d754ac5` |
| `emc-gs` | 2 Audit | `273963ae-7565-4869-82ee-81dc783c34b0` |
| `CirqueDigital` | 2 Audit | `b52c01a8-a80d-407e-ac28-66ac4dfa597c` |
| `elc-egnyte` | 12 VCAPS+ | `8b82c6da-d22f-4df6-b28d-f0b2bd4f8b95` |
| `ESRTech` | 12 VCAPS+ | `b4fd60dc-eb8f-413a-9f4c-73662cd8f45e` |
| `LogPoint` | 12 VCAPS+ | `1575a8e9-1847-4c65-908c-24e775e0d3fe` |
| `Splunk2` | 12 VCAPS+ | `48e9fb1a-093e-4c2d-941e-e4dd2b627cd2` |
| `DellChangeAuditor` | 2 Audit | `4dadf39f-d3b0-463e-9bad-256df032eccb` |
| `DellDataGovernance` | 12 VCAPS+ | `4bfa3ba7-2a10-458d-b6e9-3a248745a504` |
| `DellDataGovernance` | 12 VCAPS+ | `3d50acf6-4805-4e82-be24-d1f10080111b` |
| `DellDataGovernance` | 1 CQM | `bde15eff-9a51-4aeb-a644-286c8f0036e3` |
| `DellDataGovernance` | 2 Audit | `9cfce6d3-2438-4ad5-af97-d41946c7f01b` |
| `DellDataGovernance` | 1 CQM | `d689b952-2d2e-48a7-9666-da1fb5b58b9e` |
| `DellDataGovernance` | 2 Audit | `2e3d4c8a-fe31-456b-958e-7a263106ea8e` |
| `DellDataGovernance` | 3 Index | `d8389598-7c99-4bbf-b7a3-9413a2435469` |
| `scsAudit1` | 2 Audit | `a98daa89-7864-4a80-8fba-13f18861c6bd` |
| `scsAudit2` | 2 Audit | `0ae7f0a7-1c12-4232-97d6-71486ff90634` |
| `scsAudit3` | 2 Audit | `182efe3f-455b-43d9-8e9e-0f08839a9911` |
| `DataInsightConnector` | 2 Audit | `766c53b8-7690-4ee3-ad35-2825b8c397ac` |
| `Intrafind` | 12 VCAPS+ | `089c717a-d243-48e9-bdfb-e390cf148e82` |
| `SolarWindsARM` | 2 Audit | `27ce21d0-918c-47a4-b28a-ff432e5ff1b1` |
| `CommvaultBackup` | 5 Backup | `66380304-a056-4c66-bec6-c24ead58e300` |
| `CommvaultBackup` | 5 Backup | `e08d487e-d27e-4ba6-9a4f-f9de99c85c42` |
| `StealthVCAPS` | 12 VCAPS+ | `47c942ec-1a3d-4623-b8c5-8339129b1f9d` |
| `StealthVCAPS` | 6 CARA | `9b2fa334-7b8b-47f9-bf68-5233f09f0991` |
| `ProlionCryptoSpike` | 6 CARA | `313c1408-be16-443f-b582-a0909fda5149` |
| `PeerSoftwareCollector` | 2 Audit | `49f4da0f-055f-401c-9f83-a95ce61447f6` |

47 entries; **28 valid for the Audit facility**, which is the one this repo
enables — 27 distinct names, since `DellDataGovernance` is registered twice for
Audit with two different GUIDs.

Those 27 names are enforced, not merely documented:
`ansible/roles/cee_common/tasks/assert_partner_identity.yml` rejects any
`cee_endpoints[].name` outside them before the playbook touches a host, and
`ansible/tests/test_partner_identity.yml` covers an invented name, a
case-only difference, and a name valid for a *different* facility. If you add
or correct a row here, update that list too — they are two copies of the same
fact, and the gate is the one that runs.
