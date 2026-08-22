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

## Checking out an older commit empties this directory

Read this before you `git checkout` anything older than `v9.2.0.4`.

The artefacts *were* tracked until that release. Git removes a file that is
tracked in the commit you are leaving and absent from the one you are entering,
and `.gitignore` does not protect a file git is deleting — it only stops new
ones being added. So moving back to an older commit restores them, and coming
forward again **deletes them**, silently, with no prompt. Measured, not
theorised: it happened during the v9.2.0.4 release itself.

Nothing is lost when it does. Both rpms are recoverable from the repo:

```bash
git show v9.2.0.3:bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm \
  > bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm
git show v9.2.0.3:bin/emc_cee_SLES-9.2.0.0.x86_64.rpm | git lfs smudge \
  > bin/emc_cee_SLES-9.2.0.0.x86_64.rpm
file bin/*            # both must report RPM v3.0, never "ASCII text"
```

The RHEL rpm is an ordinary blob in history, so `git show` yields it directly.
The SLES rpm is an LFS pointer, hence the `git lfs smudge`; that needs the LFS
object, which comes from the local store or the remote. The Windows exe is the
same, and its object is 91 MB, so expect a download.

Verified against the RHEL rpm's SHA-256:
`cae1a65c9313d6644f3357e067e36d9f4a36a5f7824c6a17766c085ead6230ae`.

## It is also the protocol reference

Keep the RHEL rpm even if you only deploy Windows. Dell publishes no CEPA
specification and CEE on Windows writes no log file, so
`emc_cee_RHEL-9.2.0.0.x86_64.rpm` is the reference of record for the wire
protocol — `libConvert.so` alone yields the event bitmask, the `VC_Status` codes
and the facility numbering, and `libCEPPAPIWrapper.so` yields the partner
allowlist. The rpm is Linux and the target is often Windows; that does not
matter, both are built from one source, and this is a spec lookup rather than
something to install. `docs/cepa-protocol.md` gives the commands.
