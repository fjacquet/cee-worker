# Combined test stack: cee, cee-exporter, pstore_exporter, grafana, pstcli

Date: 2026-08-07

## Purpose

Single docker-compose to exercise, on a Linux box, the full local pipeline
across four sibling repos:

- `cee-worker` (Dell CEE, receives PowerStore CEPA events)
- `cee-exporter` (receives forwarded CEPA, exposes Prometheus metrics)
- `pstore_exporter` (PowerStore REST metrics exporter)
- `pstore-cli` (`pstcli`, one-shot Dell PowerStore CLI)

Goal: pull published GHCR images (no local builds), wire them together, and
give one Grafana + Prometheus to look at metrics from both exporters, plus an
on-demand CLI.

## Location

New files live in `cee-worker` (this repo):

- `docker-compose.test.yml`
- `.env.test.example`
- `cee-exporter-config.toml`
- `pstore-config.yaml`
- `prometheus.test.yml`
- `state/` (new, gitignored — pstcli creds/certs)

Grafana dashboards are mounted read-only from the sibling `pstore_exporter`
repo (`../pstore_exporter/grafana`), not copied.

## Services

| Service | Image | Host port | Notes |
|---|---|---|---|
| `cee` | `ghcr.io/fjacquet/cee-worker:latest` | 12228 | existing `config/emc_cee_config.xml`, one `EndPoint` set to `http://cee-exporter:12228` to test the forward path |
| `cee-exporter` | `ghcr.io/fjacquet/cee-exporter:latest` | 9228 (metrics only) | 12228 (CEPA listen) stays internal-only, reached by `cee` via service name |
| `pstore_exporter` | `ghcr.io/fjacquet/pstore_exporter:latest` | 9446 | creds via `PSTORE1_*` env vars, same as its own GHCR compose |
| `prometheus` | `prom/prometheus:latest` | 9090 | scrapes `cee-exporter:9228` and `pstore_exporter:9446` |
| `grafana` | `grafana/grafana:latest` | 3000 | admin/admin, dashboards from `pstore_exporter` only |
| `pstcli` | `ghcr.io/fjacquet/pstore-cli:latest` | none | `profiles: ["cli"]`, `docker compose run --rm pstcli ...` |

## Known gap

No Grafana dashboard exists yet for `cee-exporter` metrics — only Prometheus
scrape + raw `/metrics`/Prometheus UI browsing. Out of scope for this stack;
note it, don't build one here.

## Testing

`docker compose -f docker-compose.test.yml up -d` (default profile: cee,
cee-exporter, pstore_exporter, prometheus, grafana). CLI run separately via
`docker compose -f docker-compose.test.yml run --rm pstcli -version`.
