# Graveboards Deploy

> Unified deployment for Graveboards backend and frontend

## Quick Start

### Prerequisites

- Docker Engine 24+
- Docker Compose 2.0+
- Git

### Installation

```bash
# Clone all repositories
git clone https://github.com/graveboards/graveboards-frontend.git
git clone https://github.com/graveboards/graveboards-backend.git
git clone https://github.com/graveboards/graveboards-deploy.git

# Start all services
cd graveboards-deploy
./deploy.sh up dev
```

**Access:**
- Frontend: http://localhost:3000
- Backend: http://localhost:8000
- API Docs: http://localhost:8000/api/v1/ui

### Monitoring Stack

Prometheus, Grafana, Alertmanager, Loki, Promtail, and infrastructure exporters are enabled by default for `dev` and `prod` modes:

```bash
# Start with monitoring (default)
./deploy.sh up dev
./deploy.sh up prod

# Disable monitoring if needed
./deploy.sh up dev --no-monitoring
./deploy.sh up prod --no-monitoring

# Or use docker compose directly
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
docker compose -f docker-compose.prod.yml -f docker-compose.monitoring.yml up -d
```

**Monitoring Access (dev):**

Publish ports to the host for local access:

```bash
./deploy.sh up dev --monitoring-ports
```

- Grafana: http://localhost:3001 (default: admin / password)
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093
- Loki: http://localhost:3100

**Monitoring Access (prod):**

Only Grafana is publicly reachable, via Traefik with TLS and authentication:

```bash
./deploy.sh up prod --traefik
```

- Grafana: https://grafana.graveboards.net (Grafana login required)
- Prometheus, Loki, Alertmanager, exporters: internal-only (no host ports)

Access internal monitoring services via Grafana datasources or `ssh -L` tunnels.

**Setup Discord alerts (prod):**

1. Create a Discord webhook in your server settings (Server Settings > Integrations > Webhooks)
2. Add to `.env`: `ALERTMANAGER_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN`
3. Set a strong Grafana admin password: `GRAFANA_ADMIN_PASSWORD=<strong-password>`
4. Restart: `./deploy.sh up prod`

---

## Commands

```bash
cd graveboards-deploy
./deploy.sh up [mode] [--no-monitoring] [--nas] [--traefik] [--monitoring-ports]  # Start services
./deploy.sh down [mode] [--no-monitoring] [--nas] [--traefik] [service...]              # Stop services
./deploy.sh logs [mode] [--no-monitoring] [--nas] [--traefik] [service] - View logs
./deploy.sh test                                                    # Run tests
./deploy.sh build [mode] [--no-monitoring] [--nas] [--traefik] [service...]             # Build images
./deploy.sh status                                                  # Show status
./deploy.sh clean                                                   # Remove volumes and images
./deploy.sh help                                                    # Show help
```

**Modes:**
- `dev`      - Development (default, hot-reload, monitoring enabled)
- `prod`     - Production (Docker named volumes, monitoring enabled)
- `test`     - Testing (isolated DB/Redis, runs pytest, no monitoring)

**Flags:**
- `--no-monitoring` - Skip the monitoring stack
- `--nas`           - Include NAS volume overrides (prod only)
- `--traefik`       - Include Traefik overrides for frontend + Grafana (prod only, requires traefik-proxy network)
- `--monitoring-ports` - Publish monitoring ports to host (dev only, for local access)
- `--monitoring-traefik` - Include Traefik routes for monitoring services (prod only)

**Services (for logs):**
- `all` - All services (default)
- `backend` - Backend service
- `frontend` - Frontend service
- `postgres` - PostgreSQL database
- `redis` - Redis cache

---

## Docker Build

This project uses a multi-stage Dockerfile with separate stages for development and production:

- **development** - Full Node.js environment with hot-reload support (`npm run dev`)
- **production** - Optimized image with standalone output (`next start`)

### Build Commands

```bash
cd graveboards-deploy
./deploy.sh build dev      # Build development image
./deploy.sh build prod     # Build production image
```

**Direct Docker Build:**
```bash
# Development
docker build --target development -t frontend:dev graveboards-frontend/

# Production
docker build --target production -t frontend:latest graveboards-frontend/
```

---

## Monitoring

### Health Check

All services have built-in health checks:

```bash
# Backend health endpoint
curl http://localhost:8000/api/v1/health

# Frontend health endpoint
curl http://localhost:3000
```

### Prometheus Metrics

The backend exposes Prometheus-compatible metrics at `/metrics` (internal only):

```bash
# Fetch metrics (from within the Docker network)
docker compose -f docker-compose.yml exec backend curl -s http://localhost:8000/metrics
```

**Available metrics:**

| Metric | Type | Description |
|--------|------|-------------|
| `http_requests_total` | counter | Total HTTP requests by method, endpoint |
| `http_request_duration_seconds` | histogram | HTTP request latency (p50/p95/p99) |
| `http_requests_in_flight` | gauge | Currently processing requests |
| `db_pool_size` | gauge | Database connection pool size |
| `db_pool_checked_out` | gauge | Connections currently checked out |
| `db_pool_checked_in` | gauge | Connections currently checked in |
| `db_pool_overflow` | gauge | Overflow connections in use |
| `db_query_duration_seconds` | histogram | Database query latency by type |
| `redis_commands_total` | counter | Redis commands by type and status |
| `redis_commands_duration_seconds` | histogram | Redis command latency |
| `redis_cache_hits_total` | counter | Cache hits (GET with data) |
| `redis_cache_misses_total` | counter | Cache misses (GET with null) |
| `osu_api_requests_total` | counter | osu! API calls by endpoint and status |
| `osu_api_request_duration_seconds` | histogram | osu! API latency |
| `osu_api_errors_total` | counter | osu! API errors by type |
| `rate_limit_attempts_total` | counter | Rate limit checks (allowed/blocked) |
| `rate_limit_retries_total` | counter | Rate limit retry count |
| `daemon_service_running` | gauge | Daemon service running status |
| `daemon_jobs_total` | counter | Daemon jobs by service and status (success/failure/critical) |
| `daemon_job_duration_seconds` | histogram | Daemon job latency |
| `daemon_last_job_timestamp` | gauge | Last successful daemon job |
| `daemon_active_jobs` | gauge | Currently active daemon jobs |
| `process_cpu_seconds_total` | counter | CPU time consumed (built-in) |
| `process_resident_memory_bytes` | gauge | RSS memory usage (built-in) |
| `process_virtual_memory_bytes` | gauge | Virtual memory usage (built-in) |
| `process_start_time_seconds` | gauge | Process start time (built-in) |
| `errors_total` | counter | Errors by type and endpoint |

**Request IDs:** Every request gets a unique `request_id` (UUID) bound via `structlog.contextvars`, included in all log lines, enabling correlation between metrics and logs. Query Loki with: `{service="backend"} | json | request_id="your-request-id"`

### Logs

```bash
./deploy.sh logs [mode] [--no-monitoring] [service]
```

**Examples:**
```bash
./deploy.sh up prod                           # Start prod mode (Docker volumes)
./deploy.sh up prod --nas                     # Start prod mode (NAS volumes)
./deploy.sh up prod --traefik                 # Start prod with Traefik
./deploy.sh down prod                         # Stop prod mode
./deploy.sh logs prod all                     # View prod all logs
./deploy.sh logs dev backend                  # View dev backend logs only
```

### Backups

```bash
./backup.sh [backup_dir]          # Manual backup (keeps 7 most recent)
                                  # Backs up: PostgreSQL, Grafana dashboards/datasources,
                                  # Alertmanager silences
crontab -e                        # Add automated backup (see crontab.example)
./restore.sh <backup_file>        # Restore from backup
```

Note: Prometheus TSDB and Loki data are not backed up by default — they are regenerable
from app metrics and Docker logs. If retention matters, back up the `prometheus-data`
and `loki-data` volumes separately.

### Systemd Service

```bash
./setup-service.sh              # Interactive setup for systemd service
                                # Offers monitoring stack option for prod
```

### Environment Validation

```bash
./env-validator.sh              # Validate environment configuration
                                # Requires GRAFANA_ADMIN_PASSWORD (non-default)
                                # and ALERTMANAGER_DISCORD_WEBHOOK_URL in prod
```

---

## Configuration

### Environment Files

| File                  | Purpose                         |
|-----------------------|---------------------------------|
| `.env`                | Single active config (dev or prod) |
| `.env.example`        | Template for creating `.env`    |
| `.env.prod.example`   | Production environment template |
| `.env.test.example`   | Test environment template       |

**How to set up:**

1. **Development** - Run `./deploy.sh up dev` first; it auto-generates `.env` with interactive prompts
2. **Production** - Copy `.env.prod.example` to `.env` and fill in production values. Compose reads `.env`.

### Storage Configuration

Production deployments require volume configuration for persistent data. Choose between:

- **Docker volumes** (default, easy): Uses named Docker volumes (`postgresql-prod-data`, `redis-prod-data`, `instance-prod-data`)
- **NAS mounts** (recommended for production): Mount external storage via `--nas` flag

See [Production Deployment Guide](./docs/PRODUCTION_DEPLOYMENT.md#volume-configuration) for details.

**Required Variables:**
- `SESSION_SECRET` - Frontend session signing key (32+ chars)
- `JWT_SECRET_KEY` - JWT signing key (32+ chars)
- `OSU_CLIENT_ID`, `OSU_CLIENT_SECRET` - osu! OAuth credentials
- `ADMIN_USER_IDS` - Comma-separated osu! user IDs
- `POSTGRESQL_PASSWORD` - PostgreSQL password
- `POSTGRESQL_DATABASE` - Database name (default: `graveboards_prod`)

**Monitoring Variables (prod required):**
- `GRAFANA_ADMIN_PASSWORD` - Grafana admin password (must not be a default value)
- `ALERTMANAGER_DISCORD_WEBHOOK_URL` - Discord webhook for alerts

**Volume Variables (optional, defaults configured):**
- `POSTGRESQL_DATA_PATH` - PostgreSQL data directory
- `REDIS_DATA_PATH` - Redis data directory
- `INSTANCE_DATA_PATH` - Backend instance directory

---

## Documentation

- [Frontend README](../graveboards-frontend/README.md)
- [Backend README](../graveboards-backend/README.md)
- [Architecture Docs](../graveboards-backend/docs)
- [Production Deployment Guide](./docs/PRODUCTION_DEPLOYMENT.md)

---

## License

MIT License
