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
- **TCP 12228 open inbound on the CEE host**, from the PowerStore NAS
  server addresses. RHEL 9 ships firewalld enabled with only ssh allowed,
  so this is closed by default. The playbook opens it (see
  `cee_manage_firewall` below); if a firewall elsewhere on the path also
  filters it, open it there too.
- **Outbound HTTPS (TCP 443) from the CEE host to `cdn-ubi.redhat.com`.**
  `cee_install` resolves the rpm's dependencies from the public UBI 9
  content delivery network. Without this egress — an air-gapped host, or a
  proxy-only network — the dnf transaction fails. On a proxied network, set
  `proxy=` in `/etc/dnf/dnf.conf` on the target before running the
  playbook.
- Ansible on the control node (developed against core 2.21.2)
- The `ansible.posix` collection (see Setup) — it is not part of
  ansible-core

A Red Hat subscription is *not* required. The playbook adds the publicly
reachable UBI 9 repositories for dependency resolution.

## Setup

Install the collection dependencies first. `cee_configure` uses
`ansible.posix.firewalld`, which ansible-core does not ship, so without
this even `--syntax-check` fails:

    ansible-galaxy collection install -r ansible/requirements.yml

Then seed the inventory and variables:

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
- `cee_manage_firewall` — `true` by default: the playbook opens
  `cee_http_port/tcp` in firewalld, permanently and immediately. Set it to
  `false` only if the host firewall is managed elsewhere, and then open
  the port yourself. Leaving it false and forgetting is the failure this
  setting exists to prevent: `cee_verify` probes `127.0.0.1`, which
  firewalld does not filter, so a fully firewalled host passes every
  automated check and still receives nothing.

Every variable in the example file is required. The roles ship no
`defaults/main.yml`; `cee_preflight` asserts the full list up front rather
than letting a missing value render a quietly wrong config.

Both files are gitignored; they hold site addresses. `hosts.yml.example`
uses an ordinary login rather than `root` — every role declares
`become: true`, so sudo supplies privilege.

## Run

    cd ansible
    ansible-playbook site.yml

The playbook runs four roles in order:

| Role | Asserts / does |
|---|---|
| `cee_preflight` | Every required variable is defined; host is genuine RHEL 9; clock is synchronised; reports anything already bound to 12228 |
| `cee_install` | Drops the UBI 9 repo definitions (disabled), installs the rpm from `bin/` with those repos enabled for that transaction only, verifies `/opt/CEEPack` and the `emc_cee` unit exist |
| `cee_configure` | Validates endpoints, asserts exactly one sub-facility *and* that it is Audit, renders the config, opens the inbound port in firewalld, enables the unit |
| `cee_verify` | Unit active, port listening, log written, no unsupported-platform error |

Rerunning after a fix converges rather than stacking state. A config
change restarts `emc_cee` via handler; an unchanged config does not.

One caveat: `cee_install` stages the rpm to `/tmp` and deletes it again on
every run, so those two tasks always report `changed` even when nothing
was installed. dnf itself no-ops, so the host still converges — but a
converged run reports `changed=2`, not `changed=0`.

## Upgrading CEE

Same as the container path: remove the old rpm from `bin/`, drop the new
one in, rerun the playbook. The playbook refuses to continue if `bin/`
holds anything other than exactly one rpm.

## After deployment

Configure the PowerStore side and run the end-to-end event test:
`docs/powerstore-setup-runbook.md`.

For the first deployment against real hardware, work through
`docs/acceptance-tests.md` as well. Nothing on this branch has yet run
against a live RHEL 9 host or a live array, and that document is the plan
for establishing that it does — including how to tell a real pass from a
false one.

## Troubleshooting

**The playbook aborts on a missing module.** `couldn't resolve
module/action 'ansible.posix.firewalld'` means the collection is not
installed on the control node:
`ansible-galaxy collection install -r ansible/requirements.yml`.

**CEE is healthy but PowerStore's events never arrive.** Check the host
firewall before anything else — `cee_verify` cannot see this failure, and
it is the most likely cause on a stock RHEL 9 host. On the CEE host:

    firewall-cmd --list-ports
    firewall-cmd --state

Expected: `12228/tcp` in the port list. If it is missing, either
`cee_manage_firewall` was set to `false`, or firewalld was not installed
when the playbook ran. Those two look different in the output: a missing
firewalld prints an explicit "port unverified" message, while
`cee_manage_firewall: false` only produces `skipping:` lines with no
message at all — so check the variable as well as the output. Re-run the
playbook with `cee_manage_firewall: true`, or open it by hand:

    firewall-cmd --permanent --add-port=12228/tcp && firewall-cmd --reload

**dnf cannot resolve dependencies.** The UBI repos are installed disabled
and enabled only for the install transaction, so `dnf repolist` on the
host will *not* show them — that is expected, not a fault. A failing
transaction usually means the host cannot reach `cdn-ubi.redhat.com` over
HTTPS. Test with
`curl -sI https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/baseos/os/repodata/repomd.xml`.

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

**CEE runs, forwards nothing, and every check passes.** Look at
`cee_facilities`. `cee_configure` requires the single enabled sub-facility
to be `audit`, because the template renders `<EndPoint>` only for Audit —
any other choice would produce an enabled facility with an empty endpoint
list, which starts and logs and listens and delivers nothing.

**Access list blocking bring-up.** Set `cee_access_list_enabled: 0`
temporarily to isolate the problem, then set it back to `1`. It is the
vendor default and the right posture on a real network.

**Vendor unit and service account.** The rpm installs
`/etc/systemd/system/emc_cee.service`, which runs `emc_cee.exe -daemon`
as the `ceesvc` user (created by the rpm's `%pre` scriptlet). If the unit
fails to start, check that `ceesvc` exists and owns the paths under
`/opt/CEEPack`.
