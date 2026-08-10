# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Packaging and deployment for Dell Common Event Enabler (CEE) **9.2.0.0**
(the rpm/exe vendored in `bin/`), targeting PowerStore CEPA event
forwarding. No application source — the deliverables are Ansible roles, a
Dockerfile, and docs.

Two paths, deliberately unequal:

- **Ansible → RHEL 9 and SLES 15** (`ansible/`) — the supported path.
  Anything PowerStore-facing goes here. Windows Server is phase 2 and
  **not implemented**: the OS-family gate accepts only `RedHat` and
  `Suse` and rejects Windows by name.
- **Container** (`Dockerfile`, `docker-compose.yml`) — lab sandbox only,
  unsupported by Dell, never produced a working end-to-end event path,
  RHEL-only. Useful for poking at the CEE process itself. Not extended to
  SLES.

Prefer improving the Ansible path. Don't "fix" the container by making it
the recommended route.

## Commands

```bash
# Ansible test suite — six localhost playbooks, no VM, no network
ansible/tests/run.sh
ansible-playbook ansible/tests/test_endpoint_validation.yml   # single test

# Lint + syntax (same order CI runs them)
ansible-galaxy collection install -r ansible/requirements.yml  # must precede the next two
yamllint ansible/ .github/
cd ansible && ansible-playbook --syntax-check site.yml
ansible-lint ansible/                                          # production profile
# requirements.yml pulls two collections beyond ansible-core:
# ansible.posix (firewalld) and community.general (zypper on SLES).
# Deliberately NOT ansible.windows — no win_* module exists in the tree yet.

# Deploy (needs ansible/inventory/hosts.yml + ansible/group_vars/all.yml,
# both gitignored — copy from the .example files)
cd ansible && ansible-playbook site.yml

# Container
docker compose up -d --build
docker compose restart cee            # config-only change, no rebuild

# Combined test stack (GHCR images; needs ../pstore_exporter checked out)
cp .env.test.example .env
docker compose -f docker-compose.test.yml up -d
docker compose -f docker-compose.test.yml run --rm pstcli -version
```

`ansible.posix` is not bundled with ansible-core and `cee_configure` calls
`ansible.posix.firewalld` — without the galaxy install, even
`--syntax-check` fails. `community.general` is likewise required, for
`community.general.zypper` on the SLES branch of `cee_install`.

## Architecture

`ansible/site.yml` runs five roles in a fixed order, each with one job:

| Role | Responsibility |
|---|---|
| `cee_common` | Platform-neutral gates, pure Jinja, shared by every OS: required vars defined, endpoints valid, sub-facilities sane. Runs first — everything here can fail before a single byte reaches the host. |
| `cee_preflight` | Genuine RHEL 9 or SLES 15; clock synced; reports a pre-existing listener on `cee_http_port` |
| `cee_install` | RHEL: UBI 9 repos (installed disabled, `enablerepo`'d for one transaction), then the rpm. SLES: `community.general.zypper` installs the rpm directly, no repo setup. Both assert the `/opt/CEEPack` + `emc_cee.service` layout |
| `cee_configure` | Validates endpoints, gates sub-facilities, renders `emc_cee_config.xml.j2`, opens firewalld, enables the unit — one shared task file for RHEL and SLES |
| `cee_verify` | Unit active, port listening, log written, no unsupported-platform line — also shared |

**The dispatch routes; the gate judges.** Every role dispatches on
`ansible_os_family` (`RedHat.yml` / `Suse.yml` / `Linux.yml`). But the
platform gates in `cee_preflight` judge on the stricter
`ansible_distribution`, so Rocky and AlmaLinux (`ansible_os_family ==
'RedHat'`) are routed into `RedHat.yml` and rejected there by name, and
openSUSE (`ansible_os_family == 'Suse'`) is routed into `Suse.yml` and
rejected there by name. Dispatching on the coarser fact and judging on
the finer one is what lets one file name the specific rebuild that failed.

Gates live in their own task files under `cee_common/tasks/`
(`assert_required_vars.yml`, `assert_facilities.yml`,
`validate_endpoints.yml`) and `cee_preflight/tasks/`
(`assert_os_family.yml`, `assert_platform_RedHat.yml`,
`assert_platform_Suse.yml`), specifically so `ansible/tests/` can include
them with deliberately wrong input. Keep that split when adding a gate.

`bin/` holds three artifacts, all CEE 9.2.0.0: `emc_cee_RHEL-*.x86_64.rpm`,
`emc_cee_SLES-*.x86_64.rpm`, and `EMC_CEE_Pack_x64_9_2_0_0.exe`. Each glob
targets its own platform — the Dockerfile globs only the RHEL rpm (the
container is not extended to SLES), `cee_install`'s `RedHat.yml` globs the
RHEL rpm, and its `Suse.yml` globs the SLES rpm. Each glob requires
exactly one matching file; remove the old one before adding a new one.
`.gitattributes` puts `bin/*.rpm` and `bin/*.exe` in Git LFS, but only for
future commits — the RHEL rpm predates it and stays an ordinary blob
deliberately, to avoid rewriting history for a 4 MB file.

The design philosophy throughout: **CEE fails silently**. Its historical
failure signature was an empty log directory and no signal. Every
assertion here names the specific wrong thing rather than failing
generically, and verification is a first-class role, not a postscript.
Match that when adding checks.

## Constraints that bite

- **Genuine Red Hat or genuine SUSE only.** Both builds read
  `/etc/redhat-release` / `/etc/SuSE-release` / `/etc/os-release` and
  self-terminate with a byte-identical fatal message, `Platform is not
  supported / qualified. CEE will now terminate.`, unless they see the
  right product string. Rocky/Alma fail the RHEL build despite ABI
  compatibility, openSUSE fails the SLES build likewise — hence UBI9 as
  the container base and the `ansible_distribution` gates in
  `cee_preflight`.
- **The RHEL and SLES rpms ship an identical payload** — same
  `/opt/CEEPack`, same `emc_cee_config.xml`, same
  `/etc/systemd/system/emc_cee.service` (`WorkingDirectory=/opt/CEEPack`,
  `User=ceesvc`). That is why `cee_configure` and `cee_verify` are shared
  task files rather than branched per platform.
- **SLES needs no repository setup.** boost 1.88, openssl 3, libcurl 4
  and jansson 4 ship inside `/opt/CEEPack`; only glibc, `ld-linux` and a
  shell are external dependencies. The `ubi.repo` machinery in
  `cee_install` stays RHEL-only — there is no SLES equivalent because
  none is needed.
- **EndPoint format is `name@http://host:port`**, semicolon-separated.
  The `name@` prefix is mandatory; CEE ignores a bare URL. **Order
  matters** — CEE monitors the *first* endpoint to decide whether to
  publish at all; first one down means nobody receives events.
- **Ports must be plain unquoted integers.** The template interpolates
  verbatim, so `12228.5` or `"12228"` renders a URL CEE drops without
  logging. The integer check must run *before* the range check (Jinja's
  `int` filter does `int(float(v))` and would launder a fraction).
- **CEE 9.2.0.0 ships `Security/Http/ServerEnabled=0`** (9.3.0.0 ships it
  as `1` — confirmed by harvest on both Linux and Windows; this repo
  vendors and deploys 9.2.0.0 only). The template sets it to 1. "Nothing
  listening on 12228" almost always means CEE read a different config
  file.
- **Exactly one sub-facility, and it must be `audit`.** The template
  renders `<EndPoint>` only for Audit; any other choice yields
  `<Enabled>1</Enabled>` with an empty endpoint — starts, listens, logs,
  passes every check, forwards nothing forever.
- **`cee_verify` probes 127.0.0.1**, which firewalld does not filter. A
  firewalled host passes every check while dropping every real event.
  That's why `cee_manage_firewall` exists and why its skip path is loud.
- **Container cwd matters.** CEE's compiled-in config default is a bare
  filename resolved against cwd, so `entrypoint.sh` must `cd
  /opt/CEEPack` (the vendor systemd unit sets `WorkingDirectory` for the
  same reason). PID 1 is `emc_cee.exe` itself, so `docker logs` shows
  nothing — read `./logs` or `docker exec … tail -f`.

## Ansible idioms used here (don't "clean up")

- **Asserts are not looped.** A failure inside a looped `assert` is
  wrapped as `{"msg": "One or more items failed", "results": [...]}` and
  the real `fail_msg` is only visible nested under `results[n].msg` —
  where the tests' `rescue` blocks, which read `ansible_failed_result.msg`,
  cannot see it. Use `selectattr`/`rejectattr` over the whole list.
- **`ignore_errors: true`, never `failed_when: false`,** when a later task
  inspects the registered result. `failed_when` overwrites the result's
  own `failed` key, making a timed-out `wait_for` indistinguishable from a
  successful one.
- **No `disable_gpg_check` on the dnf install** — it's transaction-wide
  and would nullify `gpgcheck=1` for the UBI-sourced dependencies. The
  local rpm goes unverified because Dell ships the signing key only
  through their authenticated portal.
- Every negative test in `ansible/tests/` has been mutation-tested (guard
  disabled, test watched to fail, guard restored). New negative tests are
  expected to earn the same.
- **One accepted `# noqa`, and no others.**
  `ansible/tests/test_platform_assertions.yml` suppresses `name[casing]`
  on the play named `openSUSE Leap is rejected` — reviewed and accepted,
  because `openSUSE` is the correct trademark casing and ansible-lint's
  "names start with uppercase" rule is a false positive here. This is the
  repo's only suppression. Don't delete it and don't treat it as licence
  to add more; a new `noqa` needs the same scrutiny this one got.

## Docs and conventions

- `docs/ansible-deployment.md` — prerequisites, setup, troubleshooting
- `docs/powerstore-setup-runbook.md` — the array side + end-to-end event test
- `docs/acceptance-tests.md` — the plan for the first live deployment.
  Nothing here has run against real hardware; that document is explicit
  about what CI does and does not prove. Don't state otherwise.
- `docs/cee-8-x-linux-guide_en-us.pdf` covers CEE **8.x** while the rpm is
  **9.2.0.0**. Config and security semantics diverged (secure defaults).
  Treat it as a general reference, cross-check anything config-related.
- Versioning tracks the CEE release (`vX.Y.Z.W`), not SemVer. Pushing a
  `v*` tag publishes to GHCR via `.github/workflows/publish.yml`.
- `CHANGELOG.md` follows Keep a Changelog; commits are conventional
  (`fix(ansible): …`).
- Gitignored because they hold site addresses:
  `ansible/inventory/hosts.yml`, `ansible/group_vars/all.yml`,
  `ansible/group_vars/cee_linux.yml`, `ansible/group_vars/cee_windows.yml`,
  `.env`, `logs/`, `state/`. CI seeds all four from the `.example` files.
