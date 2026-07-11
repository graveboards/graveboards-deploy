# Grafana Dashboard Development Guide

Every dashboard in this directory follows a shared template. Copy the header
below into any new dashboard JSON and fill in the domain-specific values.
This ensures consistent behavior across all dashboards: datasource resolution
via variables, shared navigation, alert annotations, and standard refresh/time
settings.

## Standard Dashboard Header

```jsonc
{
  "annotations": {
    "list": [
      {
        "builtIn": 0,
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "enable": true,
        "expr": "count(ALERTS{alertstate=\"firing\"}) > 0",
        "hide": false,
        "iconColor": "red",
        "name": "Firing Alerts",
        "showIn": 0,
        "textFormat": "{{alertname}}",
        "titleFormat": "Firing Alerts",
        "type": "tags"
      }
    ]
  },
  "description": "<one-line description of what this dashboard shows>",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [
    {
      "asDropdown": true,
      "dashboards": [
        { "tags": [ "graveboards" ] }
      ],
      "includeVars": true,
      "keepTime": true,
      "targetBlank": false,
      "title": "Dashboards",
      "type": "dashboards"
    }
  ],
  "liveNow": false,
  "panels": [ ... ],
  "refresh": "30s",
  "schemaVersion": 39,
  "style": "dark",
  "tags": [ "graveboards", "<domain-tag>" ],
  "templating": {
    "list": [
      {
        "current": {},
        "hide": 0,
        "includeAll": false,
        "label": "Prometheus",
        "multi": false,
        "name": "datasource_prometheus",
        "options": [],
        "query": "prometheus",
        "refresh": 1,
        "regex": "",
        "skipUrlSync": false,
        "type": "datasource"
      },
      {
        "current": {},
        "hide": 0,
        "includeAll": false,
        "label": "Loki",
        "multi": false,
        "name": "datasource_loki",
        "options": [],
        "query": "loki",
        "refresh": 1,
        "regex": "",
        "skipUrlSync": false,
        "type": "datasource"
      }
    ]
  },
  "time": { "from": "now-6h", "to": "now" },
  "title": "<Dashboard Title>",
  "uid": "<dashboard-uid>",
  "version": 1
}
```

## Conventions

### Tags
Every dashboard must include `graveboards` plus one domain tag:
- `overview` — Platform Overview
- `api` — API & Requests
- `jobs` — Background Jobs
- `osu` — osu! API
- `host` — Host / System
- `postgres` — PostgreSQL
- `redis` — Redis
- `logs` — Logs Explorer

### Datasource variables
- `$datasource_prometheus` — resolves to the Prometheus datasource (uid: `prometheus`)
- `$datasource_loki` — resolves to the Loki datasource (uid: `Loki`)
- **Never hardcode a datasource uid in a panel target.** Always reference the variable.

### Panel datasource reference
In each panel's target, use the variable instead of a hardcoded uid:
```json
"datasource": { "type": "prometheus", "uid": "${datasource_prometheus}" }
```

### Grid rules
- The grid is 24 columns wide.
- **Hard rule: `x + w ≤ 24` for every panel.**
- Standard sizes: KPI `w=4/6, h=4`; half chart `w=12, h=8`; third `w=8, h=8`; full `w=24, h=8/10`; log stream `w=24, h=16`.
- All panels in a horizontal band share the same `h` and `y`.
- Row widths in a band must sum to 24 (12+12, 8+8+8, 6+6+6+6, 16+8).

### Units (use only valid Grafana unit ids)
| Signal | Unit |
|---|---|
| Request/op rate | `reqps` / `ops` |
| Log rate | `logs/s` |
| Duration/latency | `s` |
| Percentage (already ×100) | `percent` |
| Bytes | `bytes` |
| Bytes/sec | `Bps` |
| Time-since/uptime | `dtdurations` |
| Count | `short` |
| Bool up/down | `bool_on_off` |

### Naming
- **Dashboard titles:** Title Case, no "Graveboards" prefix.
- **Panel titles:** `Subject — qualifier`, sentence case, no units in title.
- **Row titles:** short section names (`Health`, `Traffic`, `Errors`, `Latency`).
- **Legends:** always set `legendFormat` to a short label like `{{status_code}}`.

### Color semantics
- Green = healthy/up/2xx, Blue = informational/3xx, Amber = warning/4xx, Red = error/critical/5xx/down.
- Standard thresholds: Error% green<1/amber<5/red≥5; Latency p95 green<0.5/amber<2/red≥2; Resource utilization green<70/amber<90/red≥90.

### Drill-down data links
Panels that should link to another dashboard set a `links` array:
```json
"links": [
  {
    "title": "View in Logs Explorer",
    "url": "/d/graveboards-logs?var-service=backend&var-level=error&var-logger=&var-search=&var-request_id=&from=${__from}&to=${__to}",
    "targetBlank": false,
    "type": "link"
  }
]
```

## Folder structure

```
monitoring/grafana/dashboards/
  overview/            → Platform Overview
  application/         → API & Requests, Background Jobs, osu! API
  infrastructure/      → Host / System, PostgreSQL, Redis
  logs/                → Logs Explorer
```

## Recording rules

Shared KPI expressions live in `monitoring/prometheus/rules/recording.yml`.
Dashboards should reference these recorded series instead of repeating raw
queries. Available recordings:

| Record name | Expression |
|---|---|
| `job:http_requests:rate5m` | `sum(rate(http_requests_total[5m]))` |
| `job:http_requests_errors:ratio5m` | 5xx rate / total rate |
| `job:http_request_duration:p95_5m` | `histogram_quantile(0.95, ...)` |
| `instance:node_cpu_utilization:ratio5m` | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| `job:redis_cache:hit_ratio5m` | redis cache hit ratio (windowed) |
| `job:pg_cache:hit_ratio5m` | Postgres block cache hit ratio (windowed) |

## Deploy annotations

Two mechanisms mark deploys on every dashboard's time charts:

### 1. `graveboards_build_info` metric (automatic)

The backend exports a gauge at startup:

```
graveboards_build_info{version="0.1.0", commit="a1b2c3d"} 1
```

Grafana turns version *changes* into annotations automatically via an annotation query:

```jsonc
{
  "name": "Deploys (build_info)",
  "datasource": { "type": "prometheus", "uid": "${datasource_prometheus}" },
  "enable": true,
  "expr": "changes(graveboards_build_info[1m]) > 0",
  "iconColor": "blue",
  "nameFormat": "Deploy {{version}} ({{commit}})",
  "textFormat": "{{version}} @ {{commit}}",
  "titleFormat": "Deploy",
  "type": "tags"
}
```

Add this to the `annotations.list` of any dashboard that should show deploy markers.

### 2. Grafana API annotation (from deploy script)

Set `GRAFANA_DEPLOY_ANNOTATION_TOKEN` in the environment before running `deploy.sh` / `deploy.ps1`:

```bash
export GRAFANA_DEPLOY_ANNOTATION_TOKEN="glsa_..."
export GRAFANA_URL="http://localhost:3001"  # optional, defaults to localhost:3001
./deploy.sh deploy prod
```

The deploy script pushes an annotation with the mode, operator, and timestamp. The token is a Grafana API key with `annotation:write` scope. If the token is not set the annotation is skipped silently (non-fatal).

### Adding a version stat panel

To show the current version in a dashboard KPI strip, add a stat panel:

```jsonc
{
  "datasource": { "type": "prometheus", "uid": "${datasource_prometheus}" },
  "fieldConfig": { "defaults": { "custom": { "align": "center" } } },
  "gridPos": { "h": 4, "w": 4, "x": 20, "y": 1 },
  "options": {
    "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false }
  },
  "targets": [{
    "expr": "graveboards_build_info",
    "legendFormat": "{{version}} ({{commit}})",
    "refId": "A"
  }],
  "title": "Version",
  "type": "stat"
}
```
