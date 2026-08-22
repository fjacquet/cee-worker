# bin/ — Dell vendor artefacts, not tracked

This directory is where the Dell Common Event Enabler installers go. **They are
not in git.** They are Dell's to distribute, they are available only through
Dell's authenticated support portal, and nothing here builds them — so the repo
carries the packaging and the deployment logic, and you supply the payload.

`.gitignore` excludes `bin/*.rpm`, `bin/*.exe` and `bin/*.iso`. This file is
tracked, which is the only reason the directory exists in a fresh clone.

## What to put here

All three are CEE **9.2.0.0**, the version this repo deploys.

| file | needed for |
|---|---|
| `emc_cee_RHEL-9.2.0.0.x86_64.rpm` | the RHEL 9 Ansible path, and the container |
| `emc_cee_SLES-9.2.0.0.x86_64.rpm` | the SLES 15 Ansible path |
| `EMC_CEE_Pack_x64_9_2_0_0.exe` | the Windows Server Ansible path |

Get them from Dell Support → *Common Event Enabler* → the 9.2.0.0 release. An
account with entitlement is required; there is no anonymous download.

## The names matter

Each consumer globs for its own platform's artefact, and each requires **exactly
one** match:

- `Dockerfile` → `bin/emc_cee_RHEL-*.x86_64.rpm`
- `cee_install/tasks/RedHat.yml` → `emc_cee_RHEL-*.x86_64.rpm`
- `cee_install/tasks/Suse.yml` → `emc_cee_SLES-*.x86_64.rpm`
- `cee_install/tasks/Windows.yml` → `EMC_CEE_Pack_x64_{{ cee_windows_version }}.exe`

So for the two rpms, **remove the old file before adding a new one** — two
matching rpms fail the glob assertion in `install_linux_locate.yml` by design,
rather than picking one silently. The Windows glob is the exception: it
interpolates `cee_windows_version` into the filename, so `bin/` may hold several
releases at once and each host selects its own.

The i386 SLES build Dell also ships will not match — every supported glob ends
in `.x86_64.rpm`.

## It is also the protocol reference

Keep the RHEL rpm even if you only deploy Windows. Dell publishes no CEPA
specification and CEE on Windows writes no log file, so
`emc_cee_RHEL-9.2.0.0.x86_64.rpm` is the reference of record for the wire
protocol — `libConvert.so` alone yields the event bitmask, the `VC_Status` codes
and the facility numbering, and `libCEPPAPIWrapper.so` yields the partner
allowlist. The rpm is Linux and the target is often Windows; that does not
matter, both are built from one source, and this is a spec lookup rather than
something to install. `docs/cepa-protocol.md` gives the commands.
