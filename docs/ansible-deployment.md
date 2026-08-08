# Deploying CEE with Ansible

This is the supported path for a PowerStore-facing CEE instance. Dell
supports CEE on a RHEL VM or bare metal; the container in this repo is a
lab sandbox only.

## Prerequisites

- PowerStoreOS 4.1 or later
- A **genuine RHEL 9.x** host for CEE. RHEL-compatible rebuilds such as
  Rocky and AlmaLinux do not work: CEE reads `/etc/redhat-release` and
  self-terminates unless it sees the literal Red Hat string.
- Time synchronised across the PowerStore array, the CEE host, and the
  consumer host
- SMB configured on PowerStore; NFS optional
- TCP 12228 reachable from PowerStore to the CEE host
- Ansible on the control node (developed against core 2.21.2)

A Red Hat subscription is *not* required. The playbook adds the publicly
reachable UBI 9 repositories for dependency resolution.

## Setup

    cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
    cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml

Edit both. In `group_vars/all.yml` the values that matter most:

- `cee_endpoints[].host` — the routable address of the host running
  cee-exporter. Never `127.0.0.1`, never a Docker Compose service name.
  The playbook rejects both.
- `cee_endpoints[].port` — `12229`, the host-published port that maps to
  cee-exporter's container port 12228.
- `cee_access_list` — the PowerStore NAS server addresses permitted to
  post events.

Both files are gitignored; they hold site addresses.

## Run

    cd ansible
    ansible-playbook site.yml

The playbook runs four roles in order:

| Role | Asserts / does |
|---|---|
| `cee_preflight` | Host is genuine RHEL 9; clock is synchronised; reports anything already bound to 12228 |
| `cee_install` | Adds UBI 9 repos, installs the rpm from `bin/`, verifies `/opt/CEEPack` and the `emc_cee` unit exist |
| `cee_configure` | Validates endpoints, asserts exactly one sub-facility, renders the config, enables the unit |
| `cee_verify` | Unit active, port listening, log written, no unsupported-platform error |

Every role is idempotent. Rerunning after a fix converges rather than
stacking state. A config change restarts `emc_cee` via handler; an
unchanged config does not.

## Upgrading CEE

Same as the container path: remove the old rpm from `bin/`, drop the new
one in, rerun the playbook. The playbook refuses to continue if `bin/`
holds anything other than exactly one rpm.

## After deployment

Configure the PowerStore side and run the end-to-end event test:
`docs/powerstore-setup-runbook.md`.

## Troubleshooting

**Nothing listening on 12228.** CEE 9.x ships
`Security/Http/ServerEnabled=0`. The template sets it to `1`; confirm the
rendered `/opt/CEEPack/emc_cee_config.xml` on the host actually has it,
and that CEE read that file rather than a stale copy.

**Events are not arriving at any consumer.** If `cee_endpoints` has more
than one entry, check the *first* one. CEE monitors the first endpoint in
the list to decide whether to publish at all — when it is unavailable, no
endpoint receives events, and its availability also governs whether
events are re-sent later.

**Preflight rejects the host.** The distribution message is not advisory.
CEE will not run on a rebuild; use genuine RHEL 9.

**Access list blocking bring-up.** Set `cee_access_list_enabled: 0`
temporarily to isolate the problem, then set it back to `1`. It is the
vendor default and the right posture on a real network.

**Vendor unit and service account.** The rpm installs
`/etc/systemd/system/emc_cee.service`, which runs `emc_cee.exe -daemon`
as the `ceesvc` user (created by the rpm's `%pre` scriptlet). If the unit
fails to start, check that `ceesvc` exists and owns the paths under
`/opt/CEEPack`.
