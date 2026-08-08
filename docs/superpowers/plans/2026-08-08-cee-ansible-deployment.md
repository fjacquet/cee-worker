# CEE Ansible Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Dell CEE 9.2.0.0 to a RHEL 9 VM via Ansible (Dell's supported path), keep cee-exporter/Prometheus/Grafana containerized, and document the PowerStore-side procedure.

**Architecture:** Four Ansible roles (`cee_preflight`, `cee_install`, `cee_configure`, `cee_verify`) run in sequence from `site.yml`. The CEE config is rendered from a Jinja2 template driven by `group_vars`. Tests are localhost Ansible playbooks that render the template and exercise validation logic without needing a VM. The container stays as a lab sandbox.

**Tech Stack:** Ansible core 2.21.2, Jinja2, yamllint, systemd, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-08-08-cee-ansible-deployment-design.md`

## Global Constraints

These apply to every task. Values are copied verbatim from the spec and from the rpm itself.

- CEE version is **9.2.0.0**; the rpm lives at `bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm` and must not be duplicated into `ansible/`.
- systemd unit name is **`emc_cee`** (rpm ships `/etc/systemd/system/emc_cee.service`). RPM package name for `rpm -e` is `emc_cee`.
- The unit runs `ExecStart=/opt/CEEPack/emc_cee.exe -daemon` as `User=ceesvc`, `Group=ceesvc`, `WorkingDirectory=/opt/CEEPack`, `Restart=on-abort`. **Do not modify or replace this unit file.**
- CEE inbound HTTP port is **12228**. `cee-exporter`'s host-published port is **12229** (container-internal stays 12228).
- `<EndPoint>` MUST render as `name@http://host:port`. A bare URL is invalid. Multiple endpoints are `;`-separated, and **the first entry gates delivery to all others** — if it is unavailable, CEE publishes to none.
- `<EndPoint>` host MUST NOT be a loopback address (`127.0.0.1`, `::1`, `localhost`) and MUST NOT be a Docker Compose service name.
- Target host must be **genuine Red Hat** — CEE reads `/etc/redhat-release` and self-terminates on rebuilds such as Rocky.
- Target host is **unentitled**; dependency resolution uses `ubi-9-baseos-rpms` and `ubi-9-appstream-rpms`.
- Vendor config defaults are `AccessListEnabled=1` and `Http/ServerEnabled=0`. This deployment sets `Http/ServerEnabled=1` (required, or CEE never listens) and keeps `AccessListEnabled=1`.
- Only the **Audit** sub-facility is enabled. CQM, Backup, CARA, Index, VCAPS stay `0`.
- Config schema version attribute is `<CEEConfig version="9.2.0.0">`.
- Changelog format is Keep a Changelog. Versioning tracks CEE's four-part version (`vX.Y.Z.W`), **not** SemVer.

### One sharpening of the spec

The spec's `group_vars` sketch showed singular `cee_consumer_name` / `cee_consumer_host` / `cee_consumer_port`, while its prose says the template "renders the endpoint as a list". This plan implements the list form (`cee_endpoints`) because ordering is semantically load-bearing and a singular form cannot express it. Everything else follows the spec as written.

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `ansible/ansible.cfg` | Pin stdout callback, disable host key checking prompt, set roles path |
| `ansible/site.yml` | Orchestrate the four roles in order |
| `ansible/inventory/hosts.yml.example` | Inventory shape for the CEE host |
| `ansible/group_vars/all.yml.example` | All tunable variables with documented defaults |
| `ansible/roles/cee_preflight/tasks/main.yml` | Host readiness gate |
| `ansible/roles/cee_preflight/tasks/assert_platform.yml` | Platform assertions, isolated so tests can include it |
| `ansible/roles/cee_install/tasks/main.yml` | UBI repos, rpm install, layout verification |
| `ansible/roles/cee_install/files/ubi.repo` | UBI 9 BaseOS + AppStream repo definitions |
| `ansible/roles/cee_configure/tasks/main.yml` | Render config, enable unit |
| `ansible/roles/cee_configure/tasks/validate_endpoints.yml` | Endpoint validation, isolated so tests can include it |
| `ansible/roles/cee_configure/templates/emc_cee_config.xml.j2` | The CEE 9.2.0.0 config |
| `ansible/roles/cee_configure/handlers/main.yml` | Restart `emc_cee` on config change |
| `ansible/roles/cee_verify/tasks/main.yml` | Post-deploy assertions |
| `ansible/tests/run.sh` | Test runner |
| `ansible/tests/test_template_render.yml` | Template rendering assertions |
| `ansible/tests/test_endpoint_validation.yml` | Negative tests for endpoint rules |
| `ansible/tests/test_platform_assertions.yml` | Negative tests for platform gate |
| `docs/powerstore-setup-runbook.md` | Manual PowerStore procedure + end-to-end verification |
| `docs/ansible-deployment.md` | How to run the playbook |
| `CHANGELOG.md` | Keep a Changelog |
| `.github/workflows/ansible.yml` | yamllint + syntax-check + test suite |
| `.yamllint` | Lint config tolerant of Ansible conventions |

**Modified:**

| Path | Change |
|---|---|
| `docker-compose.test.yml` | Publish `12229:12228` for `cee-exporter` |
| `README.md` | Restructure around two paths; fix Rocky→UBI9; fix EndPoint; add prerequisites |
| `.gitignore` | Ignore real inventory and group_vars |
| `docs/superpowers/specs/2026-08-06-cee-docker-container-design.md` | Append correction note |

---

### Task 1: Ansible scaffold and config template

The template is the highest-risk artifact — the missing `name@` prefix is the defect that motivated this work. It gets tests first.

**Files:**
- Create: `ansible/ansible.cfg`
- Create: `ansible/group_vars/all.yml.example`
- Create: `ansible/roles/cee_configure/templates/emc_cee_config.xml.j2`
- Create: `ansible/tests/run.sh`
- Test: `ansible/tests/test_template_render.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: the variable contract every later task uses —
  `cee_http_port` (int), `cee_https_port` (int), `cee_endpoints` (list of `{name: str, host: str, port: int}`), `cee_access_list_enabled` (int 0|1), `cee_access_list` (list of str), `cee_facilities` (dict with bool keys `audit`, `cqm`, `backup`, `cara`, `index`, `vcaps`), `cee_log_path` (str), `cee_cache_size` (int), `cee_threads` (int), `cee_debug` (int), `cee_verbose` (int).
  Also produces the template at `roles/cee_configure/templates/emc_cee_config.xml.j2`, consumed by Task 4.

- [ ] **Step 1: Write the failing test**

Create `ansible/tests/test_template_render.yml`:

```yaml
---
# Renders the CEE config template with known variables and asserts the
# result. Runs entirely on localhost: no VM, no CEE install, no network.
- name: Render emc_cee_config.xml and assert its contents
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cee_http_port: 12228
    cee_https_port: 12443
    cee_cache_size: 100
    cee_threads: 20
    cee_debug: 0
    cee_verbose: 0
    cee_log_path: /opt/CEEPack/logs/
    cee_access_list_enabled: 1
    cee_access_list:
      - 10.20.30.40
      - 10.20.30.41
    cee_endpoints:
      - name: ceeexporter
        host: 10.10.10.10
        port: 12229
    cee_facilities:
      audit: true
      cqm: false
      backup: false
      cara: false
      index: false
      vcaps: false
  tasks:
    - name: Render the template
      ansible.builtin.template:
        src: ../roles/cee_configure/templates/emc_cee_config.xml.j2
        dest: /tmp/cee_render_test.xml
        mode: "0644"

    - name: Slurp the rendered file
      ansible.builtin.slurp:
        src: /tmp/cee_render_test.xml
      register: rendered

    - name: Decode to a plain string
      ansible.builtin.set_fact:
        cee_xml: "{{ rendered.content | b64decode }}"

    - name: EndPoint carries the mandatory consumer-name prefix
      ansible.builtin.assert:
        that:
          - "'<EndPoint>ceeexporter@http://10.10.10.10:12229</EndPoint>' in cee_xml"
        fail_msg: >-
          EndPoint must render as name@http://host:port. The Dell CEE guide
          (line 284) and the Peer Software PowerStore guide both require the
          consumer-name prefix; CEE ignores a bare URL.

    - name: Audit is the only enabled sub-facility
      ansible.builtin.assert:
        that:
          - cee_xml is search('<Audit>\\s*<Configuration>\\s*<Enabled>1</Enabled>')
          - cee_xml is search('<CQM>\\s*<Configuration>\\s*<Enabled>0</Enabled>')
          - cee_xml is search('<VCAPS>\\s*<Configuration>\\s*<Enabled>0</Enabled>')
        fail_msg: "Exactly one sub-facility (Audit) must be enabled."

    - name: HTTP server is enabled and bound to the configured port
      ansible.builtin.assert:
        that:
          - "'<HttpPort>12228</HttpPort>' in cee_xml"
          - cee_xml is search('<Http>\\s*<ServerEnabled>1</ServerEnabled>')
        fail_msg: >-
          CEE 9.x ships Http/ServerEnabled=0. Without 1 here CEE never binds
          a listener and fails silently.

    - name: Access list is enabled and populated
      ansible.builtin.assert:
        that:
          - "'<AccessListEnabled>1</AccessListEnabled>' in cee_xml"
          - "'10.20.30.40' in cee_xml"
          - "'10.20.30.41' in cee_xml"
        fail_msg: "AccessList must contain every configured PowerStore address."

    - name: Schema version matches the shipped rpm
      ansible.builtin.assert:
        that:
          - '''<CEEConfig version="9.2.0.0">'' in cee_xml'
        fail_msg: "Config version attribute must match CEE 9.2.0.0."

    - name: Log path is set (the vendor default config omits LogFile entirely)
      ansible.builtin.assert:
        that:
          - "'<Path>/opt/CEEPack/logs/</Path>' in cee_xml"
        fail_msg: "LogFile/Path must be set so cee_verify can find the log."

- name: Multiple endpoints render semicolon-separated in declared order
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cee_http_port: 12228
    cee_https_port: 12443
    cee_cache_size: 100
    cee_threads: 20
    cee_debug: 0
    cee_verbose: 0
    cee_log_path: /opt/CEEPack/logs/
    cee_access_list_enabled: 0
    cee_access_list: []
    cee_endpoints:
      - name: primary
        host: 10.10.10.10
        port: 12229
      - name: secondary
        host: 10.10.10.11
        port: 12229
    cee_facilities:
      audit: true
      cqm: false
      backup: false
      cara: false
      index: false
      vcaps: false
  tasks:
    - name: Render the template
      ansible.builtin.template:
        src: ../roles/cee_configure/templates/emc_cee_config.xml.j2
        dest: /tmp/cee_render_multi.xml
        mode: "0644"

    - name: Slurp the rendered file
      ansible.builtin.slurp:
        src: /tmp/cee_render_multi.xml
      register: rendered_multi

    - name: Decode to a plain string
      ansible.builtin.set_fact:
        cee_xml_multi: "{{ rendered_multi.content | b64decode }}"

    - name: Endpoints join with ';' preserving order
      ansible.builtin.assert:
        that:
          - >-
            '<EndPoint>primary@http://10.10.10.10:12229;secondary@http://10.10.10.11:12229</EndPoint>'
            in cee_xml_multi
        fail_msg: >-
          Order is load-bearing: CEE gates delivery to every endpoint on the
          availability of the first one in the list.
```

Create `ansible/tests/run.sh`:

```sh
#!/bin/sh
# Runs every localhost test playbook. No VM or CEE install required.
set -e
cd "$(dirname "$0")"
for t in test_*.yml; do
    printf '\n== %s\n' "$t"
    ansible-playbook "$t"
done
printf '\nAll Ansible tests passed.\n'
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x ansible/tests/run.sh
ansible/tests/run.sh
```

Expected: FAIL on the first playbook with `Could not find or access '../roles/cee_configure/templates/emc_cee_config.xml.j2'`.

- [ ] **Step 3: Write the template**

Create `ansible/roles/cee_configure/templates/emc_cee_config.xml.j2`.

Structure mirrors the config shipped inside the rpm exactly, so CEE sees a schema it recognises. The only additions are the `<LogFile>` block (absent from the vendor default) and the rendered values.

```jinja
{#
  CEE 9.2.0.0 configuration.

  Rendered from group_vars — do not edit on the target host; the next
  playbook run overwrites it.

  EndPoint format is `name@http://host:port`, semicolon-separated for
  multiple consumers. The prefix is mandatory (Dell CEE guide line 284).
  Ordering matters: CEE monitors the first endpoint in the list to decide
  whether to publish at all, so if the first consumer is down, none of the
  others receive events either.
#}
<?xml version="1.0" encoding="utf-8"?>
<CEEConfig version="9.2.0.0">
  <CEPP>
    <Audit>
      <Configuration>
        <Enabled>{{ 1 if cee_facilities.audit else 0 }}</Enabled>
        <EndPoint>{% if cee_facilities.audit %}{% for e in cee_endpoints %}{{ e.name }}@http://{{ e.host }}:{{ e.port }}{% if not loop.last %};{% endif %}{% endfor %}{% endif %}</EndPoint>
      </Configuration>
    </Audit>
    <CQM>
      <Configuration>
        <Enabled>{{ 1 if cee_facilities.cqm else 0 }}</Enabled>
        <EndPoint></EndPoint>
      </Configuration>
    </CQM>
    <Backup>
      <Configuration>
        <Enabled>{{ 1 if cee_facilities.backup else 0 }}</Enabled>
        <EndPoint></EndPoint>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
      </Configuration>
    </Backup>
    <CARA>
      <Configuration>
        <Enabled>{{ 1 if cee_facilities.cara else 0 }}</Enabled>
        <EndPoint></EndPoint>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
      </Configuration>
    </CARA>
    <Index>
      <Configuration>
        <Enabled>{{ 1 if cee_facilities.index else 0 }}</Enabled>
        <EndPoint></EndPoint>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
        <SplunkHEC>
          <Index></Index>
          <Host server="" token=""/>
        </SplunkHEC>
      </Configuration>
    </Index>
    <VCAPS>
      <Configuration>
        <Enabled>{{ 1 if cee_facilities.vcaps else 0 }}</Enabled>
        <EndPoint></EndPoint>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
      </Configuration>
    </VCAPS>
  </CEPP>
  <Configuration>
    <CacheSize>{{ cee_cache_size }}</CacheSize>
    <Debug>{{ cee_debug }}</Debug>
    <HeartBeatIntervalSecs>10</HeartBeatIntervalSecs>
    <InstrIntervalSecs>10</InstrIntervalSecs>
    <NumberOfThreads>{{ cee_threads }}</NumberOfThreads>
    <Verbose>{{ cee_verbose }}</Verbose>
    <HttpPort>{{ cee_http_port }}</HttpPort>
    <HttpsPort>{{ cee_https_port }}</HttpsPort>
    <WatchDog>
      <RestartCount>2</RestartCount>
      <RestartDelay>5</RestartDelay>
      <ResetRestartCountAfter>86400</ResetRestartCountAfter>
    </WatchDog>
    <LogFile>
      <Path>{{ cee_log_path }}</Path>
      <MaxSize>100</MaxSize>
    </LogFile>
    <Security>
      <Access>
        <AccessListEnabled>{{ cee_access_list_enabled }}</AccessListEnabled>
        <AccessList>{{ cee_access_list | join(',') }}</AccessList>
      </Access>
      <Http>
        <ServerEnabled>1</ServerEnabled>
      </Http>
      <Https>
        <ServerEnabled>0</ServerEnabled>
        <Certificate></Certificate>
        <PrivateKey></PrivateKey>
        <CAStore></CAStore>
        <MinTLSVer>1.2</MinTLSVer>
        <Platforms verify="0"/>
        <Partners verify="0"/>
      </Https>
    </Security>
  </Configuration>
</CEEConfig>
```

Create `ansible/ansible.cfg`:

```ini
[defaults]
roles_path = roles
inventory = inventory/hosts.yml
host_key_checking = True
stdout_callback = yaml
interpreter_python = auto_silent
```

Create `ansible/group_vars/all.yml.example`:

```yaml
---
# Copy to all.yml and edit. all.yml is gitignored — it holds site addresses.

# CEE inbound listener. PowerStore posts CEPA events here. 12228 is the
# documented default and the PowerStore side expects it (Dell CEE guide,
# line 709). Changing it means changing the PowerStore publishing pool too.
cee_http_port: 12228
cee_https_port: 12443

# Where CEE forwards events. `name` becomes the mandatory `name@` prefix.
# `host` must be a routable IP or FQDN — never 127.0.0.1, never a Docker
# Compose service name (CEE runs on a VM and cannot resolve compose DNS).
#
# ORDER MATTERS: CEE monitors the first endpoint to decide whether to
# publish at all. If the first one is down, no endpoint receives events.
cee_endpoints:
  - name: ceeexporter
    host: 10.10.10.10     # the Docker host running cee-exporter
    port: 12229           # host-published port, maps to container 12228

# Restrict which sources may post events. 1 is the vendor default and the
# right posture on a real network. Set to 0 only to isolate a bring-up
# problem, then set it back.
cee_access_list_enabled: 1
cee_access_list:
  - 10.20.30.40           # PowerStore NAS server address

# Exactly one sub-facility should be true. Audit is the synchronous
# real-time path cee-exporter speaks. VCAPS is async bulk delivery and
# needs exporter-side work before it can be enabled.
cee_facilities:
  audit: true
  cqm: false
  backup: false
  cara: false
  index: false
  vcaps: false

# Logging and tuning. cee_log_path must end with a trailing slash.
cee_log_path: /opt/CEEPack/logs/
cee_cache_size: 100
cee_threads: 20
cee_debug: 0
cee_verbose: 0
```

Append to `.gitignore`:

```
# ansible: real inventory and vars hold site addresses
ansible/inventory/hosts.yml
ansible/group_vars/all.yml
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
ansible/tests/run.sh
```

Expected: PASS. Both plays report `ok` with zero failed tasks.

- [ ] **Step 5: Commit**

```bash
git add ansible/ansible.cfg ansible/group_vars/all.yml.example \
        ansible/roles/cee_configure/templates/emc_cee_config.xml.j2 \
        ansible/tests/run.sh ansible/tests/test_template_render.yml .gitignore
git commit -m "feat(ansible): CEE 9.2 config template with tested EndPoint format"
```

---

### Task 2: Endpoint validation

Bad endpoints are the failure mode that cost five commits. Validation lives in its own task file so it can be exercised without a target host.

**Files:**
- Create: `ansible/roles/cee_configure/tasks/validate_endpoints.yml`
- Test: `ansible/tests/test_endpoint_validation.yml`

**Interfaces:**
- Consumes: `cee_endpoints` from Task 1.
- Produces: `roles/cee_configure/tasks/validate_endpoints.yml`, included by `cee_configure/tasks/main.yml` in Task 4.

- [ ] **Step 1: Write the failing test**

Create `ansible/tests/test_endpoint_validation.yml`:

```yaml
---
- name: Loopback endpoints are rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cee_endpoints:
      - name: ceeexporter
        host: 127.0.0.1
        port: 12229
  tasks:
    - name: Expect validation to fail
      block:
        - name: Validate
          ansible.builtin.include_tasks: ../roles/cee_configure/tasks/validate_endpoints.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "127.0.0.1 was accepted. The Peer guide forbids loopback here."
      rescue:
        - name: Confirm it failed for the loopback reason
          ansible.builtin.assert:
            that:
              - "'loopback' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Validation failed, but not with the loopback message."

- name: Compose service names are rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cee_endpoints:
      - name: ceeexporter
        host: cee-exporter
        port: 12229
  tasks:
    - name: Expect validation to fail
      block:
        - name: Validate
          ansible.builtin.include_tasks: ../roles/cee_configure/tasks/validate_endpoints.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "A bare hostname was accepted; CEE on a VM cannot resolve compose DNS."
      rescue:
        - name: Confirm it failed for the resolvability reason
          ansible.builtin.assert:
            that:
              - "'resolve' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Validation failed, but not with the resolvability message."

- name: An empty endpoint list is rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cee_endpoints: []
  tasks:
    - name: Expect validation to fail
      block:
        - name: Validate
          ansible.builtin.include_tasks: ../roles/cee_configure/tasks/validate_endpoints.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "An empty endpoint list was accepted; Audit would have nowhere to publish."
      rescue:
        - name: Confirm it failed for the empty-list reason
          ansible.builtin.assert:
            that:
              - "'at least one' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Validation failed, but not with the empty-list message."

- name: A well-formed endpoint passes
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cee_endpoints:
      - name: ceeexporter
        host: 10.10.10.10
        port: 12229
  tasks:
    - name: Validate
      ansible.builtin.include_tasks: ../roles/cee_configure/tasks/validate_endpoints.yml
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ansible/tests/run.sh
```

Expected: FAIL with `Could not find or access '../roles/cee_configure/tasks/validate_endpoints.yml'`.

- [ ] **Step 3: Write the validation tasks**

Create `ansible/roles/cee_configure/tasks/validate_endpoints.yml`:

```yaml
---
# Endpoint rules, enforced before anything is written to the target host.
# Each of these has cost real debugging time, so each fails with the
# reason rather than a generic assertion error.

- name: At least one endpoint must be defined
  ansible.builtin.assert:
    that:
      - cee_endpoints | length > 0
    fail_msg: >-
      cee_endpoints must contain at least one entry. With Audit enabled and
      no endpoint, CEE starts but publishes nowhere.

- name: Every endpoint must declare name, host and port
  ansible.builtin.assert:
    that:
      - item.name is defined and item.name | length > 0
      - item.host is defined and item.host | length > 0
      - item.port is defined
    fail_msg: >-
      Endpoint {{ item }} is incomplete. `name` becomes the mandatory
      `name@` prefix in the rendered EndPoint; without it CEE ignores the
      entry.
  loop: "{{ cee_endpoints }}"
  loop_control:
    label: "{{ item.name | default('<unnamed>') }}"

- name: Endpoint hosts must not be loopback
  ansible.builtin.assert:
    that:
      - item.host not in ['127.0.0.1', '::1', 'localhost']
      - not (item.host is match('^127\\.'))
    fail_msg: >-
      Endpoint '{{ item.name }}' points at loopback ({{ item.host }}). The
      Peer Software PowerStore guide explicitly forbids a loopback address
      between CEE and its consumer, even when they are co-hosted. Use the
      routable address of the host running cee-exporter.
  loop: "{{ cee_endpoints }}"
  loop_control:
    label: "{{ item.name }}"

- name: Endpoint hosts must be an IP address or a dotted FQDN
  ansible.builtin.assert:
    that:
      - (item.host is match('^\\d{1,3}(\\.\\d{1,3}){3}$')) or ('.' in item.host)
    fail_msg: >-
      Endpoint '{{ item.name }}' host '{{ item.host }}' is a bare hostname.
      CEE runs on a VM and cannot resolve Docker Compose service names.
      Use an IP address or a fully-qualified domain name.
  loop: "{{ cee_endpoints }}"
  loop_control:
    label: "{{ item.name }}"

- name: Endpoint ports must be in range
  ansible.builtin.assert:
    that:
      - item.port | int > 0
      - item.port | int < 65536
    fail_msg: "Endpoint '{{ item.name }}' port {{ item.port }} is out of range."
  loop: "{{ cee_endpoints }}"
  loop_control:
    label: "{{ item.name }}"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
ansible/tests/run.sh
```

Expected: PASS. All four plays complete; the three negative plays reach their `rescue` blocks and assert successfully.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/cee_configure/tasks/validate_endpoints.yml \
        ansible/tests/test_endpoint_validation.yml
git commit -m "feat(ansible): reject loopback, bare-hostname and empty endpoints"
```

---

### Task 3: Preflight role

**Files:**
- Create: `ansible/roles/cee_preflight/tasks/assert_platform.yml`
- Create: `ansible/roles/cee_preflight/tasks/main.yml`
- Test: `ansible/tests/test_platform_assertions.yml`

**Interfaces:**
- Consumes: `cee_http_port` from Task 1.
- Produces: role `cee_preflight`, invoked first by `site.yml` in Task 6.

- [ ] **Step 1: Write the failing test**

Create `ansible/tests/test_platform_assertions.yml`:

```yaml
---
- name: A RHEL rebuild is rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_distribution: Rocky
    ansible_distribution_major_version: "9"
  tasks:
    - name: Expect the platform gate to fail
      block:
        - name: Assert platform
          ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_platform.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "Rocky was accepted. CEE self-terminates on non-Red Hat hosts."
      rescue:
        - name: Confirm it failed for the distribution reason
          ansible.builtin.assert:
            that:
              - "'Red Hat' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Failed, but not with the genuine-Red-Hat message."

- name: RHEL 8 is rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_distribution: RedHat
    ansible_distribution_major_version: "8"
  tasks:
    - name: Expect the platform gate to fail
      block:
        - name: Assert platform
          ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_platform.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "RHEL 8 was accepted; the guide requires 9.x for CEE 9.2."
      rescue:
        - name: Confirm it failed for the version reason
          ansible.builtin.assert:
            that:
              - "'9' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Failed, but not with the major-version message."

- name: Genuine RHEL 9 passes
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_distribution: RedHat
    ansible_distribution_major_version: "9"
  tasks:
    - name: Assert platform
      ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_platform.yml
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ansible/tests/run.sh
```

Expected: FAIL with `Could not find or access '../roles/cee_preflight/tasks/assert_platform.yml'`.

- [ ] **Step 3: Write the role**

Create `ansible/roles/cee_preflight/tasks/assert_platform.yml`:

```yaml
---
# Platform gate. Isolated from main.yml so it can be tested with
# overridden facts on a workstation.

- name: Host must be genuine Red Hat Enterprise Linux
  ansible.builtin.assert:
    that:
      - ansible_distribution == 'RedHat'
    fail_msg: >-
      Detected '{{ ansible_distribution }}'. CEE reads /etc/redhat-release
      and self-terminates with "Platform is not supported / qualified"
      unless it sees the literal Red Hat string. RHEL-compatible rebuilds
      such as Rocky and AlmaLinux fail this check despite being ABI
      compatible.

- name: Host must be RHEL major version 9
  ansible.builtin.assert:
    that:
      - ansible_distribution_major_version == '9'
    fail_msg: >-
      Detected RHEL {{ ansible_distribution_major_version }}. CEE 9.2
      requires RHEL 9.x per the Peer Software PowerStore configuration
      guide.
```

Create `ansible/roles/cee_preflight/tasks/main.yml`:

```yaml
---
- name: Gather facts needed for the platform gate
  ansible.builtin.setup:
    gather_subset:
      - distribution

- name: Assert the platform is supported
  ansible.builtin.include_tasks: assert_platform.yml

- name: Check whether chrony is present
  ansible.builtin.stat:
    path: /usr/bin/chronyc
  register: cee_chronyc

- name: Time must be synchronised
  when: cee_chronyc.stat.exists
  block:
    - name: Query chrony tracking state
      ansible.builtin.command: chronyc tracking
      register: cee_chrony_tracking
      changed_when: false
      failed_when: false

    - name: Clock must not be unsynchronised
      ansible.builtin.assert:
        that:
          - cee_chrony_tracking.rc == 0
          - "'Not synchronised' not in cee_chrony_tracking.stdout"
        fail_msg: >-
          Clock is not synchronised. The PowerStore array, this CEE host and
          the consumer must agree on time or events are rejected or
          misordered. Fix chrony before continuing.

- name: Warn when chrony is absent
  ansible.builtin.debug:
    msg: >-
      chronyc not found — time synchronisation could not be verified.
      PowerStore, CEE and the consumer must share synchronised time.
  when: not cee_chronyc.stat.exists

- name: Check whether the CEE port is already in use
  ansible.builtin.wait_for:
    port: "{{ cee_http_port }}"
    host: 127.0.0.1
    state: stopped
    timeout: 3
  register: cee_port_free
  failed_when: false

- name: Report a pre-existing listener on the CEE port
  ansible.builtin.debug:
    msg: >-
      Something is already listening on {{ cee_http_port }}. If this is a
      previous emc_cee instance the playbook will reconfigure it; if it is
      another service, CEE will fail to bind.
  when: cee_port_free is failed
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
ansible/tests/run.sh
```

Expected: PASS. All three plays complete.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/cee_preflight/ ansible/tests/test_platform_assertions.yml
git commit -m "feat(ansible): preflight gate for RHEL 9, time sync and port"
```

---

### Task 4: Install role

**Files:**
- Create: `ansible/roles/cee_install/files/ubi.repo`
- Create: `ansible/roles/cee_install/tasks/main.yml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: CEE installed at `/opt/CEEPack`, unit file at `/etc/systemd/system/emc_cee.service`. Sets fact `cee_rpm_local` (str, absolute path to the bundled rpm). Task 5 depends on the unit existing.

The rpm bundles its own boost, OpenSSL, curl and jansson shared objects under `/opt/CEEPack`, so its external dependency surface is small. UBI repos are reachable without a Red Hat subscription and supply the remainder.

- [ ] **Step 1: Write the repo definition**

Create `ansible/roles/cee_install/files/ubi.repo`:

```ini
# UBI 9 repositories. Reachable without a Red Hat subscription, which
# matters because the CEE target host is unentitled. The CEE rpm installs
# cleanly on stock UBI9 (see the project Dockerfile), so this package set
# is known to satisfy it.
[ubi-9-baseos-rpms]
name = Red Hat Universal Base Image 9 - BaseOS
baseurl = https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/baseos/os
enabled = 1
gpgcheck = 1
gpgkey = file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

[ubi-9-appstream-rpms]
name = Red Hat Universal Base Image 9 - AppStream
baseurl = https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/appstream/os
enabled = 1
gpgcheck = 1
gpgkey = file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
```

- [ ] **Step 2: Write the install tasks**

Create `ansible/roles/cee_install/tasks/main.yml`:

```yaml
---
- name: Install UBI 9 repositories
  ansible.builtin.copy:
    src: ubi.repo
    dest: /etc/yum.repos.d/ubi.repo
    owner: root
    group: root
    mode: "0644"
  become: true

- name: Locate the bundled CEE rpm
  ansible.builtin.set_fact:
    cee_rpm_candidates: >-
      {{ query('ansible.builtin.fileglob',
               playbook_dir + '/../bin/emc_cee_RHEL-*.x86_64.rpm') }}

- name: Exactly one CEE rpm must be present in bin/
  ansible.builtin.assert:
    that:
      - cee_rpm_candidates | length == 1
    fail_msg: >-
      Expected exactly one emc_cee_RHEL-*.x86_64.rpm in bin/, found
      {{ cee_rpm_candidates | length }}. Remove the old rpm before adding a
      new one — the Dockerfile globs the same directory and has the same
      requirement.

- name: Record the rpm path
  ansible.builtin.set_fact:
    cee_rpm_local: "{{ cee_rpm_candidates[0] }}"

- name: Copy the CEE rpm to the target
  ansible.builtin.copy:
    src: "{{ cee_rpm_local }}"
    dest: /tmp/{{ cee_rpm_local | basename }}
    owner: root
    group: root
    mode: "0644"
  become: true

- name: Install CEE
  ansible.builtin.dnf:
    name: /tmp/{{ cee_rpm_local | basename }}
    state: present
    disable_gpg_check: true
  become: true
  notify: Restart emc_cee

- name: Remove the staged rpm
  ansible.builtin.file:
    path: /tmp/{{ cee_rpm_local | basename }}
    state: absent
  become: true

- name: Verify the CEE layout
  ansible.builtin.stat:
    path: "{{ item }}"
  register: cee_layout
  loop:
    - /opt/CEEPack/emc_cee.exe
    - /opt/CEEPack/emc_cee_svc
    - /etc/systemd/system/emc_cee.service
  become: true

- name: Every expected CEE path must exist
  ansible.builtin.assert:
    that:
      - item.stat.exists
    fail_msg: >-
      {{ item.item }} is missing after install. The rpm layout changed, or
      the install silently failed. The unit name this playbook manages is
      `emc_cee`; if the rpm now ships a different unit, update
      cee_configure and cee_verify to match.
  loop: "{{ cee_layout.results }}"
  loop_control:
    label: "{{ item.item }}"

- name: Ensure the log directory exists and is writable by the service user
  ansible.builtin.file:
    path: "{{ cee_log_path }}"
    state: directory
    owner: ceesvc
    group: ceesvc
    mode: "0750"
  become: true
```

The handler `Restart emc_cee` is defined in Task 5's `cee_configure` role. Ansible resolves handler names globally across roles in a play, so notifying it from here is valid as long as `cee_configure` runs in the same play — which `site.yml` guarantees.

- [ ] **Step 3: Verify syntax**

```bash
cd ansible && ansible-playbook --syntax-check tests/test_template_render.yml
yamllint roles/cee_install/
```

Expected: no syntax errors, no lint errors.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/cee_install/
git commit -m "feat(ansible): install CEE rpm via UBI repos on unentitled RHEL 9"
```

---

### Task 5: Configure and verify roles

**Files:**
- Create: `ansible/roles/cee_configure/tasks/main.yml`
- Create: `ansible/roles/cee_configure/handlers/main.yml`
- Create: `ansible/roles/cee_verify/tasks/main.yml`

**Interfaces:**
- Consumes: the template and variables from Task 1, `validate_endpoints.yml` from Task 2, the installed layout from Task 4.
- Produces: handler `Restart emc_cee`, notified by Task 4 and by config changes. Renders `/opt/CEEPack/emc_cee_config.xml`.

- [ ] **Step 1: Write the configure tasks**

Create `ansible/roles/cee_configure/tasks/main.yml`:

```yaml
---
- name: Validate endpoints before touching the host
  ansible.builtin.include_tasks: validate_endpoints.yml

- name: Exactly one sub-facility may be enabled
  ansible.builtin.assert:
    that:
      - (cee_facilities.values() | select('equalto', true) | list | length) == 1
    fail_msg: >-
      {{ cee_facilities.values() | select('equalto', true) | list | length }}
      sub-facilities are enabled. Enable exactly one. Audit is the
      synchronous real-time path cee-exporter speaks; VCAPS is async bulk
      delivery and needs exporter-side work first.

- name: Render the CEE configuration
  ansible.builtin.template:
    src: emc_cee_config.xml.j2
    dest: /opt/CEEPack/emc_cee_config.xml
    owner: ceesvc
    group: ceesvc
    mode: "0640"
    backup: true
  become: true
  notify: Restart emc_cee

- name: Enable and start CEE
  ansible.builtin.systemd_service:
    name: emc_cee
    enabled: true
    state: started
    daemon_reload: true
  become: true
```

Create `ansible/roles/cee_configure/handlers/main.yml`:

```yaml
---
- name: Restart emc_cee
  ansible.builtin.systemd_service:
    name: emc_cee
    state: restarted
    daemon_reload: true
  become: true
```

- [ ] **Step 2: Write the verify tasks**

Create `ansible/roles/cee_verify/tasks/main.yml`:

```yaml
---
# The container failed silently: empty logs, no signal, nothing to
# diagnose. Verification is a first-class step here, and each assertion
# names the specific thing that is wrong.

- name: Flush handlers so any pending restart happens before verification
  ansible.builtin.meta: flush_handlers

- name: Query the emc_cee unit state
  ansible.builtin.systemd_service:
    name: emc_cee
  register: cee_unit
  become: true

- name: emc_cee must be running
  ansible.builtin.assert:
    that:
      - cee_unit.status.ActiveState == 'active'
    fail_msg: >-
      emc_cee is {{ cee_unit.status.ActiveState }}, not active. Check
      `journalctl -u emc_cee -n 50` and the CEE log under
      {{ cee_log_path }}.

- name: CEE must be listening on its inbound port
  ansible.builtin.wait_for:
    port: "{{ cee_http_port }}"
    host: 127.0.0.1
    state: started
    timeout: 30
  register: cee_listening
  failed_when: false

- name: Report a missing listener with the likely cause
  ansible.builtin.assert:
    that:
      - cee_listening is not failed
    fail_msg: >-
      Nothing is listening on {{ cee_http_port }}. CEE 9.x ships
      Security/Http/ServerEnabled=0 by default; confirm the rendered
      /opt/CEEPack/emc_cee_config.xml has it set to 1 and that CEE actually
      read that file.

- name: Find the CEE log files
  ansible.builtin.find:
    paths: "{{ cee_log_path }}"
    patterns: "*.log"
  register: cee_logs
  become: true

- name: CEE must have written a log
  ansible.builtin.assert:
    that:
      - cee_logs.files | length > 0
    fail_msg: >-
      No log files under {{ cee_log_path }}. CEE did not start, or
      LogFile/Path in the rendered config does not match. An empty log
      directory was exactly the container's failure signature.

- name: Read the CEE log
  ansible.builtin.slurp:
    src: "{{ (cee_logs.files | sort(attribute='mtime') | last).path }}"
  register: cee_log_content
  become: true

- name: Log must not report an unsupported platform
  ansible.builtin.assert:
    that:
      - "'Platform is not supported' not in (cee_log_content.content | b64decode)"
    fail_msg: >-
      CEE reports an unsupported platform. /etc/redhat-release does not
      contain the literal Red Hat string this host claimed to have.

- name: Report the verified state
  ansible.builtin.debug:
    msg: >-
      CEE active, listening on {{ cee_http_port }}, logging to
      {{ cee_log_path }}. Endpoints:
      {% for e in cee_endpoints %}{{ e.name }}@http://{{ e.host }}:{{ e.port }}{% if not loop.last %}, {% endif %}{% endfor %}.
      Next: run the two-stage event test in docs/powerstore-setup-runbook.md.
```

- [ ] **Step 3: Verify syntax and lint**

```bash
cd ansible && yamllint roles/cee_configure/ roles/cee_verify/
ansible/tests/run.sh
```

Expected: no lint errors; the existing test suite still passes (Task 2's tests include `validate_endpoints.yml`, which `cee_configure/tasks/main.yml` now also includes).

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/cee_configure/tasks/main.yml \
        ansible/roles/cee_configure/handlers/main.yml \
        ansible/roles/cee_verify/
git commit -m "feat(ansible): render CEE config and verify the running service"
```

---

### Task 6: Playbook entry point, inventory, and deployment doc

**Files:**
- Create: `ansible/site.yml`
- Create: `ansible/inventory/hosts.yml.example`
- Create: `docs/ansible-deployment.md`
- Create: `.yamllint`

**Interfaces:**
- Consumes: all four roles from Tasks 2–5.
- Produces: the single command `ansible-playbook site.yml` that runs the whole deployment.

- [ ] **Step 1: Write the playbook and inventory**

Create `ansible/site.yml`:

```yaml
---
- name: Deploy Dell CEE to a RHEL 9 host
  hosts: cee
  gather_facts: true
  roles:
    - cee_preflight
    - cee_install
    - cee_configure
    - cee_verify
```

Create `ansible/inventory/hosts.yml.example`:

```yaml
---
# Copy to hosts.yml and edit. hosts.yml is gitignored.
#
# The CEE host must be genuine RHEL 9 — the playbook refuses to continue
# otherwise, because CEE self-terminates on RHEL rebuilds.
all:
  children:
    cee:
      hosts:
        cee01.example.com:
          ansible_host: 10.10.10.20
          ansible_user: root
```

Create `.yamllint`:

```yaml
---
# Ansible YAML uses long lines and `on:`/`yes` truthiness that the default
# yamllint profile flags. Relax only those.
extends: default

rules:
  line-length:
    max: 160
    level: warning
  truthy:
    allowed-values: ["true", "false"]
    check-keys: false
  comments-indentation: disable

ignore: |
  .github/
```

- [ ] **Step 2: Verify the playbook parses**

```bash
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
cd ansible && ansible-playbook --syntax-check site.yml
```

Expected: `playbook: site.yml` with no errors.

- [ ] **Step 3: Verify lint passes across the tree**

```bash
yamllint ansible/
```

Expected: no errors.

- [ ] **Step 4: Write the deployment doc**

Create `docs/ansible-deployment.md`:

```markdown
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
```

- [ ] **Step 5: Commit**

```bash
git add ansible/site.yml ansible/inventory/hosts.yml.example \
        docs/ansible-deployment.md .yamllint
git commit -m "feat(ansible): site playbook, inventory example and deployment guide"
```

---

### Task 7: PowerStore runbook

**Files:**
- Create: `docs/powerstore-setup-runbook.md`

**Interfaces:**
- Consumes: the deployed CEE host from Task 6.
- Produces: the three-stage verification procedure referenced by `cee_verify` and by `docs/ansible-deployment.md`.

- [ ] **Step 1: Write the runbook**

Create `docs/powerstore-setup-runbook.md`:

```markdown
# PowerStore Events Publishing — Setup Runbook

Manual procedure. The `dellemc.powerstore` Ansible collection has 46
modules and none covers Events Publishing, CEPA, or publishing pools, so
automating this needs raw REST calls against a path that must be
introspected from a live array. That is deferred.

Complete `docs/ansible-deployment.md` first — CEE must be running and
listening before PowerStore has anywhere to publish to.

## Prerequisites

- PowerStoreOS 4.1 or later
- CEE 9.2 or later, deployed and verified
- Time synchronised across the array, the CEE host, and the consumer host
- SMB configured on the NAS server; NFS optional
- TCP 12228 open from the array to the CEE host

## Procedure

Perform these in order. Each step depends on the previous one.

1. **Enable Events Publishing on the NAS server.**
   Navigate to the NAS server, then *Security & Events* → *Events
   Publishing*. Enable it.

2. **Create an Events Publisher**, or modify the existing one.

3. **Create a Publishing Pool.** Add the CEE host's IP address or FQDN to
   the *Event Publishing (CEPA) Server* list.

4. **Select Post-Events.** Select all, then uncheck these five:
   - `CloseDir`
   - `OpenDir`
   - `FileRead`
   - `OpenFileReadOffline`
   - `OpenFileWriteOffline`

5. **Leave Pre-Events and Post-Error-Events unchecked.** Pre-events are
   synchronous and block the client until the consumer answers; the audit
   path does not need them.

6. **Enable monitoring per filesystem.** For each filesystem to monitor:
   select it, open the *Security & Events* tab, enable Events Publishing,
   select the protocols (SMB, NFS, or both), and apply.

## Verification

Three stages, in order. Each isolates one leg, so a failure tells you
which side is broken rather than only that something is.

```mermaid
flowchart TD
    S1["Stage 1 — CEE healthy<br/>unit active, :12228 listening, log written"]
    S2["Stage 2 — consumer reachable<br/>PUT synthetic event from the CEE host"]
    S3["Stage 3 — full path<br/>touch a file on a monitored filesystem"]

    F1["Fix CEE first.<br/>Check Http/ServerEnabled=1 and journalctl -u emc_cee"]
    F2["Consumer, network or port mapping.<br/>Check the 12229:12228 mapping and the firewall"]
    F3["CEE config or PowerStore.<br/>Check the name@ prefix, then Events Publishing on<br/>both the NAS server and the filesystem"]
    OK["Path verified end to end"]

    S1 -->|pass| S2
    S1 -->|fail| F1
    S2 -->|pass| S3
    S2 -->|fail| F2
    S3 -->|pass| OK
    S3 -->|fail| F3
```

### Stage 1 — CEE is healthy

Already asserted by the `cee_verify` role at the end of the playbook run.
To recheck by hand on the CEE host:

    systemctl is-active emc_cee
    ss -lntp | grep 12228
    tail -n 50 /opt/CEEPack/logs/*.log

Expected: `active`, a listener on 12228, and a log with no
`Platform is not supported`.

### Stage 2 — the consumer is reachable and parsing

Run this **from the CEE host**, not from your workstation. The point is to
prove that the exact path CEE will use — that host, that address, that
port — reaches a working consumer.

Record cee-exporter's current event count:

    curl -s http://<docker-host>:9228/metrics | grep '^cee_events_received_total'

Send a synthetic event. cee-exporter accepts `PUT` on `/` with a CEPA XML
body; `POST` is rejected:

    curl -s -o /dev/null -w '%{http_code}\n' -X PUT \
      -H 'Content-Type: text/xml' \
      --data-binary '<?xml version="1.0" encoding="utf-8"?>
    <CEEEvent>
      <EventType>CreateFile</EventType>
      <Timestamp>2026-08-08T12:00:00Z</Timestamp>
      <FilePath>/runbook/stage2-probe.txt</FilePath>
      <Username>runbook</Username>
      <Domain>TEST</Domain>
      <ClientAddress>10.10.10.20</ClientAddress>
    </CEEEvent>' \
      http://<docker-host>:12229/

Expected: HTTP `200`. Then read the counter again:

    curl -s http://<docker-host>:9228/metrics | grep '^cee_events_received_total'

Expected: the counter increased by one, and the event appears in
cee-exporter's output.

**What this does and does not prove.** It proves the consumer is running,
reachable from the CEE host at the address CEE is configured to use, and
parsing CEPA XML. It does *not* exercise CEE's own forwarding, because
CEE's inbound source API is the interface PowerStore speaks and there is
no documented way to inject a synthetic event into it. That leg is
exercised by Stage 3.

The isolation is still worth having: if Stage 2 passes from the CEE host
and Stage 3 fails, the consumer, the network path and the port mapping
are all ruled out, leaving CEE's configuration or the PowerStore side.
If Stage 2 fails, stop — there is no point configuring PowerStore until
the consumer answers.

Common Stage 2 failures:

- Connection refused → the `12229:12228` mapping is missing from
  `docker-compose.test.yml`, or a firewall on the Docker host blocks it.
- HTTP 405 → the request used `POST`. cee-exporter requires `PUT`.
- HTTP 200 but no counter movement → the XML did not parse; check
  cee-exporter's log.

### Stage 3 — the PowerStore → CEE leg

On a client with the monitored filesystem mounted, create and delete a
file:

    touch /mnt/<share>/cee-runbook-test.txt
    rm /mnt/<share>/cee-runbook-test.txt

Expected: corresponding `CreateFile` and `DeleteFile` events appear in
cee-exporter's output (`/var/log/cee-exporter/audit.evtx` in the test
stack) within a few seconds.

If Stage 2 passed and Stage 3 did not, the problem is on the PowerStore
side: recheck that Events Publishing is enabled on both the NAS server
*and* the individual filesystem, that the protocol selection matches how
the client mounted, and that the CEE host address in the publishing pool
is correct.

## Notes

- Port 12228 is CEE's **inbound** port — where PowerStore posts events.
  It is distinct from `<EndPoint>`, the **outbound** hop to the consumer.
  Both legs can use 12228 when they are on different hosts; in this
  repo's test stack the consumer is published on 12229 so the CEE host
  and the Docker host may be the same machine.
- Do not use a loopback address in `<EndPoint>` even when CEE and the
  consumer are co-hosted. The Peer Software guide forbids it.
```

- [ ] **Step 2: Verify links resolve**

```bash
grep -o 'docs/[a-z0-9./-]*\.md' docs/powerstore-setup-runbook.md docs/ansible-deployment.md | sort -u
ls docs/ansible-deployment.md docs/powerstore-setup-runbook.md
```

Expected: every referenced path exists.

- [ ] **Step 3: Commit**

```bash
git add docs/powerstore-setup-runbook.md
git commit -m "docs: PowerStore events publishing runbook with staged verification"
```

---

### Task 8: Compose port change and documentation corrections

**Files:**
- Modify: `docker-compose.test.yml`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-06-cee-docker-container-design.md`

**Interfaces:**
- Consumes: the endpoint contract from Task 1 (`12229` host port).
- Produces: a reachable cee-exporter listener for the CEE VM.

- [ ] **Step 1: Publish cee-exporter's CEPA port**

In `docker-compose.test.yml`, replace the `cee-exporter` `ports` block and its preceding comment with:

```yaml
    # 12229:12228 rather than 12228:12228. CEE's inbound listener owns
    # 12228 by specification, and with CEE now on a VM its consumer must
    # be reachable off-host. Publishing the exporter on 12229 lets the CEE
    # host and the Docker host be the same machine without colliding.
    ports:
      - "9228:9228"
      - "12229:12228"
```

- [ ] **Step 2: Verify the compose file is valid**

```bash
docker compose -f docker-compose.test.yml config >/dev/null && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Correct the 2026-08-06 spec**

Append to `docs/superpowers/specs/2026-08-06-cee-docker-container-design.md`:

```markdown

---

## Correction — 2026-08-08

This spec stated that "Rocky Linux 9 is a RHEL-compatible rebuild,
satisfying this". That is false. CEE reads `/etc/redhat-release` and
self-terminates with "Platform is not supported / qualified" unless it
sees the literal Red Hat string, so ABI compatibility is not sufficient.
The container base moved to `registry.access.redhat.com/ubi9/ubi` in
commit `4cd8007`.

The containerized approach did not reach a working event path. CEE is now
deployed to a RHEL 9 VM via Ansible; see
`docs/superpowers/specs/2026-08-08-cee-ansible-deployment-design.md`. The
container remains as a lab sandbox and is not a supported configuration.

This note is appended rather than edited in place: the spec recorded a
belief that testing disproved, and that record is the useful part.
```

- [ ] **Step 4: Restructure the README**

Rewrite `README.md` so that:

- The opening line reads: *"Dell Common Event Enabler (CEE) 9.2.0.0 — deployed to RHEL 9 with Ansible for PowerStore-facing use, and packaged as a container for local experimentation."* The current "Docker container on Rocky Linux 9" is wrong on both counts.
- A **Prerequisites** section appears before either path, listing: PowerStoreOS 4.1+, CEE 9.2 minimum, genuine RHEL 9.x (rebuilds rejected), time synchronised across array/CEE/consumer, SMB configured, TCP 12228 reachable.
- **Two paths** are presented, in this order, with the reason stated:
  1. *Ansible on RHEL 9 (supported)* — links `docs/ansible-deployment.md`. Note that Dell supports CEE on a VM or bare metal.
  2. *Container (lab sandbox, unsupported by Dell)* — keeps the existing quick start, plus the existing caveats about PID 1 and `docker logs`. Add one sentence: the container is not a supported Dell configuration and has not produced a working end-to-end event path; use the Ansible path for anything PowerStore-facing.
- Every EndPoint example gains the mandatory prefix. The line currently
  reading ``set one sub-facility's `<EndPoint>` in `config/emc_cee_config.xml` to `http://cee-exporter:12228` `` becomes ``set one sub-facility's `<EndPoint>` in `config/emc_cee_config.xml` to `ceeexporter@http://cee-exporter:12228` — the `name@` prefix is mandatory and CEE ignores a bare URL``.
- The test-stack service list changes `cee-exporter (9228, metrics only — its 12228 CEPA listener stays internal)` to `cee-exporter (9228 metrics, 12229 CEPA — maps to container 12228)`.
- The combined-test-stack section links `docs/powerstore-setup-runbook.md` for the end-to-end verification.
- The existing "Out of scope" and "Upgrading CEE" sections are kept. "Upgrading CEE" gains a line noting the same `bin/` rpm serves both the container build and the playbook.

- [ ] **Step 5: Verify no stale references remain**

```bash
grep -rn "Rocky" README.md docs/*.md || echo "no stale Rocky references"
grep -rn 'EndPoint.*http' README.md | grep -v '@http' || echo "all EndPoint examples carry the name@ prefix"
```

Expected: both report their "no stale" message.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.test.yml README.md \
        docs/superpowers/specs/2026-08-06-cee-docker-container-design.md
git commit -m "docs: two-path README, publish exporter on 12229, correct 08-06 spec"
```

---

### Task 9: Changelog and CI

**Files:**
- Create: `CHANGELOG.md`
- Create: `.github/workflows/ansible.yml`

**Interfaces:**
- Consumes: the test suite from Tasks 1–3.
- Produces: CI enforcement of lint, syntax, and tests on every push.

- [ ] **Step 1: Write the changelog**

Create `CHANGELOG.md`:

```markdown
# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

Versioning tracks the packaged CEE release (`vX.Y.Z.W`) rather than
Semantic Versioning, because this repo packages and deploys a specific
Dell CEE build and the useful version to know is CEE's own.

## [Unreleased]

### Added

- Ansible deployment of CEE 9.2.0.0 to RHEL 9: `cee_preflight`,
  `cee_install`, `cee_configure` and `cee_verify` roles driven by
  `ansible/site.yml`
- Config rendered from `emc_cee_config.xml.j2`, with endpoint validation
  that rejects loopback addresses, bare hostnames and empty endpoint lists
- Localhost test suite (`ansible/tests/run.sh`) covering template
  rendering, endpoint validation and the platform gate — no VM required
- Installation from the publicly reachable UBI 9 repositories, so the CEE
  host does not need a Red Hat subscription
- `docs/ansible-deployment.md` — deployment procedure and troubleshooting
- `docs/powerstore-setup-runbook.md` — PowerStore Events Publishing setup
  and three-stage end-to-end verification
- Prerequisites documented for the first time: PowerStoreOS 4.1+, CEE 9.2
  minimum, genuine RHEL 9.x, time synchronisation, TCP 12228

### Fixed

- `<EndPoint>` now renders as `name@http://host:port`. The consumer-name
  prefix is mandatory per the Dell CEE guide and the Peer Software
  PowerStore guide; the previous bare URL was silently ignored by CEE
- README described the container base as Rocky Linux 9; it has been UBI9
  since `4cd8007`, because CEE rejects RHEL rebuilds

### Changed

- `cee-exporter` publishes its CEPA listener on host port 12229 (mapping
  to container 12228). CEE's inbound listener owns 12228, so this lets the
  CEE host and the Docker host be the same machine
- README restructured around two paths: Ansible on RHEL 9 (supported) and
  the container (lab sandbox, not a supported Dell configuration)

## [0.1.0] - 2026-08-06

### Added

- CEE 9.2.0.0 packaged as a container, published to GHCR on tagged
  releases
- Combined test stack (`docker-compose.test.yml`): cee-worker,
  cee-exporter, pstore_exporter, Prometheus, Grafana, and pstcli
```

- [ ] **Step 2: Write the CI workflow**

Create `.github/workflows/ansible.yml`:

```yaml
---
name: Ansible

on:
  push:
    branches: ["**"]
  pull_request:
  workflow_dispatch: {}

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install Ansible and linters
        run: pip install "ansible-core>=2.17" ansible-lint yamllint

      - name: yamllint
        run: yamllint ansible/ .github/

      - name: Seed inventory and vars from the committed examples
        run: |
          cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
          cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml

      - name: Syntax check
        working-directory: ansible
        run: ansible-playbook --syntax-check site.yml

      - name: ansible-lint
        run: ansible-lint ansible/

      - name: Run the localhost test suite
        run: ansible/tests/run.sh
```

- [ ] **Step 3: Verify the workflow's steps pass locally**

```bash
yamllint ansible/ .github/
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
(cd ansible && ansible-playbook --syntax-check site.yml)
ansible/tests/run.sh
```

Expected: every command exits 0. `ansible-lint` is not installed locally; CI covers it. If it reports issues on the first CI run, fix them and note the fixes under `[Unreleased] → Fixed`.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md .github/workflows/ansible.yml
git commit -m "chore: add changelog and Ansible lint/test CI"
```

---

## Definition of Done

- `ansible/tests/run.sh` passes.
- `yamllint ansible/ .github/` is clean.
- `ansible-playbook --syntax-check site.yml` passes.
- `docker compose -f docker-compose.test.yml config` validates.
- No `Rocky` references remain in `README.md` or `docs/*.md`.
- Every `<EndPoint>` example in the repo carries the `name@` prefix.
- The three-stage verification in `docs/powerstore-setup-runbook.md` has
  been run against the live array, and Stage 3 produced `CreateFile` and
  `DeleteFile` events in cee-exporter's output.

The last item is the one that matters. Everything before it is
scaffolding that has never yet been proven end to end.
