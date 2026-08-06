# CEE Docker Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package Dell CEE 8.x (`bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm`) into a Rocky Linux 9 Docker container that runs as a long-lived CEPA daemon, with runtime-mounted config for pointing at different PowerStore test environments without rebuilding, a `docker-compose.yml` for one-command runs, and a GitHub Actions workflow that publishes the image to GHCR on tagged releases.

**Architecture:** Multi-stage-free single Dockerfile (`FROM rockylinux:9`) installs the rpm at build time; a foreground `entrypoint.sh` starts the CEE service and tails its log to keep the container alive. `emc_cee_config.xml` is never baked into the image — it's bind-mounted from `config/emc_cee_config.xml` on the host so switching PowerStore endpoints is a config edit + restart, not a rebuild. GHCR publish is a separate, decoupled GitHub Actions workflow triggered by version tags.

**Tech Stack:** Docker, Docker Compose, Rocky Linux 9, GitHub Actions, `docker/build-push-action`.

## Global Constraints

- Base image: `rockylinux:9` (RHEL-compatible, satisfies doc's "Red Hat Enterprise version 7.x and higher, 64-bit" requirement).
- CEE installs via `rpm -i emc_cee_RHEL-<version>.x86_64.rpm`, default location `/opt/CEEPack`.
- Service managed via `emc_cee_svc {start|stop|restart}`; default `HttpPort` is `12228`.
- Config file is `emc_cee_config.xml`, must live at `/opt/CEEPack/emc_cee_config.xml` inside the container — never baked into the image, always bind-mounted at runtime.
- Dockerfile must glob `bin/*.rpm` (not hardcode the version) so dropping a new rpm + rebuild is the entire upgrade flow.
- GHCR publish triggers only on `push` of tags matching `v*`, plus `workflow_dispatch` — never on every `main` push.
- Repo and GHCR package are public (explicit user choice, already accepted in spec).

---

## File Structure

- `Dockerfile` — builds the Rocky Linux 9 image, installs the rpm, sets up entrypoint.
- `entrypoint.sh` — foreground wrapper: starts `emc_cee_svc`, tails CEE's log to keep the container alive.
- `.dockerignore` — keeps build context lean (excludes `docs/`, `.git/`, etc).
- `config/emc_cee_config.xml` — sample config (all CEPA sub-facilities disabled, matching doc defaults), the file users copy/edit per PowerStore target. Bind-mounted at runtime, never baked in.
- `docker-compose.yml` — one-command run: builds image, mounts config + logs, exposes port 12228.
- `.github/workflows/publish.yml` — builds and pushes the image to GHCR on version tags or manual dispatch.
- `README.md` — usage: build, run, upgrade, point at a PowerStore target, GHCR pull.

---

### Task 1: Sample CEE config file

**Files:**
- Create: `config/emc_cee_config.xml`

**Interfaces:**
- Produces: a valid `emc_cee_config.xml` with `version="8.9.8.0"`, all sub-facilities (`Audit`, `CQM`, `Backup`, `CARA`, `Index`, `VCAPS`) present with `Enabled>0`, empty `EndPoint`, and the doc's default `<Configuration>` block (`CacheSize>100`, `HttpPort>12228`, `WatchDog`, `LogFile Path>/opt/CEEPack/`, `Security/Access` with `AccessListEnabled>0`). This is Task 3's bind-mount target and Task 4's compose volume source — its path and root element name (`CEEConfig`) must match what those tasks reference.

- [ ] **Step 1: Write the sample config file**

```xml
<?xml version="1.0" encoding="utf-8"?>
<CEEConfig version="8.9.8.0">
  <CEPP>
    <Audit>
      <Configuration>
        <Enabled>0</Enabled>
        <EndPoint/>
      </Configuration>
    </Audit>
    <CQM>
      <Configuration>
        <Enabled>0</Enabled>
        <EndPoint/>
      </Configuration>
    </CQM>
    <Backup>
      <Configuration>
        <Enabled>0</Enabled>
        <EndPoint/>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
      </Configuration>
    </Backup>
    <CARA>
      <Configuration>
        <Enabled>0</Enabled>
        <EndPoint/>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
      </Configuration>
    </CARA>
    <Index>
      <Configuration>
        <Enabled>0</Enabled>
        <EndPoint/>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
        <SplunkHEC>
          <Index/>
          <Host server="" token=""/>
        </SplunkHEC>
      </Configuration>
    </Index>
    <VCAPS>
      <Configuration>
        <Enabled>0</Enabled>
        <EndPoint/>
        <FeedInterval>60</FeedInterval>
        <MaxEventsPerFeed>100</MaxEventsPerFeed>
      </Configuration>
    </VCAPS>
  </CEPP>
  <Configuration>
    <CacheSize>100</CacheSize>
    <Debug>0</Debug>
    <HeartBeatIntervalSecs>10</HeartBeatIntervalSecs>
    <InstrIntervalSecs>10</InstrIntervalSecs>
    <NumberOfThreads>20</NumberOfThreads>
    <Verbose>0</Verbose>
    <HttpPort>12228</HttpPort>
    <WatchDog>
      <RestartCount>2</RestartCount>
      <RestartDelay>5</RestartDelay>
      <ResetRestartCountAfter>86400</ResetRestartCountAfter>
    </WatchDog>
    <LogFile>
      <Path>/opt/CEEPack/</Path>
      <MaxSize>100</MaxSize>
    </LogFile>
    <Security>
      <Access>
        <AccessListEnabled>0</AccessListEnabled>
        <AccessList/>
      </Access>
    </Security>
  </Configuration>
</CEEConfig>
```

- [ ] **Step 2: Validate XML is well-formed**

Run: `xmllint --noout config/emc_cee_config.xml` (or `python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('config/emc_cee_config.xml')"` if `xmllint` unavailable)
Expected: no output / no exception (well-formed).

- [ ] **Step 3: Commit**

```bash
git add config/emc_cee_config.xml
git commit -m "feat: add sample CEE config with all sub-facilities disabled"
```

---

### Task 2: Dockerfile and .dockerignore

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Consumes: `bin/*.rpm` (existing rpm at `bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm`), `entrypoint.sh` (produced by Task 3 — reference it now, Task 3 creates the actual file next).
- Produces: a buildable image tagged `cee-worker:local` exposing port `12228`, with CEE installed at `/opt/CEEPack` and `/entrypoint.sh` as the container entrypoint. Task 3 depends on `/entrypoint.sh` existing at this exact path inside the image. Task 4 (compose) depends on this Dockerfile building successfully via `build: .`.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM rockylinux:9

RUN dnf install -y \
    initscripts \
    glibc \
    && dnf clean all

COPY bin/*.rpm /tmp/
RUN rpm -i /tmp/*.rpm && rm -f /tmp/*.rpm

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 12228

ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: Write .dockerignore**

```
.git
docs
config
logs
*.md
```

- [ ] **Step 3: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat: add Dockerfile installing CEE rpm on Rocky Linux 9"
```

Note: this task's build (Task 3, Step 2) will fail until `entrypoint.sh` exists — that's expected, Task 3 creates it immediately after.

---

### Task 3: entrypoint.sh and first successful build

**Files:**
- Create: `entrypoint.sh`

**Interfaces:**
- Consumes: `emc_cee_svc` (installed by the rpm at a location on `$PATH`, per doc chapter 4).
- Produces: a running foreground process that keeps the container alive and forwards CEE's log output to `docker logs`.

- [ ] **Step 1: Write entrypoint.sh**

```sh
#!/bin/sh
set -e

emc_cee_svc start

LOG_PATH="/opt/CEEPack"
LOG_GLOB="$LOG_PATH"/*.log

# Wait for the log file to appear before tailing (CEE creates it on first start).
for i in $(seq 1 30); do
  if ls $LOG_GLOB >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

exec tail -F $LOG_GLOB
```

- [ ] **Step 2: Build the image**

Run: `docker build -t cee-worker:local .`
Expected: build completes successfully, final layer is `ENTRYPOINT ["/entrypoint.sh"]`.

- [ ] **Step 3: Run the container and verify it stays up**

Run: `docker run -d --name cee-test -p 12228:12228 cee-worker:local`
Then: `sleep 5 && docker ps --filter name=cee-test`
Expected: container listed with status `Up`.

- [ ] **Step 4: Verify CEE process is running inside the container**

Run: `docker exec cee-test ps aux | grep -i cee`
Expected: at least one CEE-related process listed (exact process name confirmed from this output — update `entrypoint.sh`'s log glob if the actual log filename differs from `*.log`).

- [ ] **Step 5: Clean up test container**

Run: `docker rm -f cee-test`

- [ ] **Step 6: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: add entrypoint starting CEE service and tailing logs"
```

---

### Task 4: docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: `Dockerfile` (Task 2), `config/emc_cee_config.xml` (Task 1).
- Produces: `docker compose up -d` bringing up the `cee` service with config and log volumes mounted and port `12228` published.

- [ ] **Step 1: Write docker-compose.yml**

```yaml
services:
  cee:
    build: .
    image: cee-worker:local
    ports:
      - "12228:12228"
    volumes:
      - ./config/emc_cee_config.xml:/opt/CEEPack/emc_cee_config.xml
      - ./logs:/opt/CEEPack/logs
    restart: unless-stopped
```

- [ ] **Step 2: Create the host logs directory**

Run: `mkdir -p logs`

- [ ] **Step 3: Bring the stack up**

Run: `docker compose up -d --build`
Expected: build succeeds, `cee` service reported running.

- [ ] **Step 4: Verify config mount took effect**

Run: `docker compose exec cee cat /opt/CEEPack/emc_cee_config.xml`
Expected: output matches `config/emc_cee_config.xml` content from Task 1.

- [ ] **Step 5: Verify logs are visible on the host**

Run: `ls logs/`
Expected: at least one log file present (if empty, check whether CEE's actual log path differs from `/opt/CEEPack/logs` — adjust the compose volume and `entrypoint.sh` glob together to match the real path observed in Task 3 Step 4's process inspection, then re-run this step).

- [ ] **Step 6: Tear down**

Run: `docker compose down`

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml logs/.gitkeep
git commit -m "feat: add docker-compose for one-command CEE runs"
```

(Add an empty `logs/.gitkeep` before committing if `logs/` needs to exist in the repo but stay otherwise empty — `git add logs/.gitkeep` covers this; actual log files stay untracked via `.gitignore`, added in Task 6's README task if not already excluded.)

---

### Task 5: GitHub Actions GHCR publish workflow

**Files:**
- Create: `.github/workflows/publish.yml`

**Interfaces:**
- Consumes: `Dockerfile` (Task 2), repo's `GITHUB_TOKEN` (implicit, no new secret needed for GHCR with default permissions).
- Produces: on a `v*` tag push or manual dispatch, pushes `ghcr.io/<owner>/cee-worker:<tag>` and `ghcr.io/<owner>/cee-worker:latest`.

- [ ] **Step 1: Write the workflow file**

```yaml
name: Publish to GHCR

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch: {}

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract tag
        id: meta
        run: echo "tag=${GITHUB_REF#refs/tags/}" >> "$GITHUB_OUTPUT"

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.tag || 'manual' }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
```

- [ ] **Step 2: Validate workflow YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/publish.yml'))"` (or `yamllint .github/workflows/publish.yml` if available)
Expected: no error.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/publish.yml
git commit -m "feat: add GHCR publish workflow on version tags"
```

- [ ] **Step 4: Push and tag to trigger a real run (only once repo has a remote)**

Run: `git push -u origin main` then `git tag v9.2.0.0 && git push origin v9.2.0.0`
Expected: Actions tab shows the workflow running; on success, `ghcr.io/<owner>/cee-worker:v9.2.0.0` and `:latest` are listed under the repo's Packages.

(This step requires a GitHub remote to exist — coordinate with the user before pushing/tagging, per repo's git safety norms. If no remote yet, stop after Step 3 and flag this as the remaining step for the user to trigger.)

---

### Task 6: README

**Files:**
- Create: `README.md`
- Create: `.gitignore`

**Interfaces:**
- Consumes: all prior tasks' file paths and commands (Dockerfile, docker-compose.yml, config path, GHCR image name).
- Produces: a top-level usage doc; no other task depends on this one.

- [ ] **Step 1: Write .gitignore**

```
logs/*
!logs/.gitkeep
```

- [ ] **Step 2: Write README.md**

```markdown
# cee-worker

Dell Common Event Enabler (CEE) 8.x packaged as a Docker container on Rocky Linux 9, for testing against a PowerStore environment.

## Quick start

    cp config/emc_cee_config.xml config/emc_cee_config.xml.bak  # optional, keep a copy
    docker compose up -d --build

CEE's HTTP endpoint is published on port 12228. Logs land in ./logs.

## Pointing at a PowerStore target

Edit config/emc_cee_config.xml — set the relevant sub-facility's <Enabled>
to 1 and its <EndPoint> to the consumer application address(es), per the
CEE Linux guide (docs/cee-8-x-linux-guide_en-us.pdf). Then:

    docker compose restart cee

No rebuild needed for config-only changes.

## Upgrading CEE

1. Drop the new emc_cee_RHEL-<version>.x86_64.rpm into bin/ (remove the old
   one first — the Dockerfile globs bin/*.rpm and expects exactly one file).
2. docker compose build --no-cache
3. docker compose up -d

## Pulling from GHCR

    docker pull ghcr.io/<owner>/cee-worker:latest

Published on tagged releases (git tag vX.Y.Z.W && git push origin vX.Y.Z.W)
via .github/workflows/publish.yml, or manually via the Actions tab
(workflow_dispatch).

## Out of scope

RabbitMQ messaging (Unity/VNX-only, CEE <=8.8.2.1) and Splunk indexing
setup are not configured by default — see the config file's Index/VCAPS
sections and the linked guide if needed.
```

- [ ] **Step 3: Commit**

```bash
git add README.md .gitignore
git commit -m "docs: add README covering usage, upgrade, and GHCR pull"
```

---

## Self-Review Notes

- **Spec coverage:** Dockerfile/Rocky base (Task 2), entrypoint/long-lived daemon (Task 3), runtime-mounted config (Tasks 1, 4), docker-compose (Task 4), rpm-drop upgrade flow (README in Task 6, Dockerfile glob in Task 2), GHCR publish on tags (Task 5) — all spec sections covered. RabbitMQ/Splunk/TLS explicitly out of scope per spec, reflected in README's Out of scope section.
- **Known unknowns flagged inline, not hidden:** exact CEE log filename/path (Task 3 Step 4, Task 4 Step 5) is confirmed empirically during execution rather than assumed — plan tells the implementer exactly what to check and adjust if the glob doesn't match.
- **Type/path consistency:** `/opt/CEEPack/emc_cee_config.xml` referenced identically in Task 1 (produces), Task 3 (entrypoint's `LOG_PATH`), Task 4 (compose mount) and README. Image tag `cee-worker:local` consistent across Task 2 build and Task 4 compose. GHCR image name driven by `${{ github.repository }}`, no hardcoded owner.
