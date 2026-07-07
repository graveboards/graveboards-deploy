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

Prometheus, Grafana, Alertmanager, Loki, and Promtail are enabled by default for `dev` and `prod` modes:

```bash
# Start with monitoring (default)
./deploy.sh up dev
./deploy.sh up prod

# Disable monitoring if needed
./deploy.sh up dev disable-monitoring
./deploy.sh up prod disable-monitoring

# Or use docker compose directly
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
docker compose -f docker-compose.prod.yml -f docker-compose.monitoring.yml up -d
```

**Monitoring Access:**
- Grafana: http://localhost:3001 (default: admin / password)
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093
- Loki: http://localhost:3100

**Setup Discord alerts (prod):**
1. Create a Discord webhook in your server settings (Server Settings > Integrations > Webhooks)
2. Add to `.env.prod`: `ALERTMANAGER_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN`
3. Restart: `./deploy.sh up prod`

---

## Commands

```bash
cd graveboards-deploy
./deploy.sh up [mode] [disable-monitoring]  # Start services
./deploy.sh down [mode]             # Stop services
./deploy.sh logs [mode] [service]   # View logs
./deploy.sh test                    # Run tests
./deploy.sh build [mode]            # Build images
./deploy.sh status                  # Show status
./deploy.sh clean                   # Remove volumes and images
./deploy.sh help                    # Show help
```

**Modes:**
- `dev`      - Development (default, hot-reload, monitoring enabled)
- `prod`     - Production (Docker named volumes, monitoring enabled)
- `prod-nas` - Production (NAS/external mounts, monitoring enabled)
- `test`     - Testing (isolated DB/Redis, runs pytest, no monitoring)

**Monitoring:**
- Enabled by default for `dev`, `prod`, and `prod-nas`
- Pass `disable-monitoring` to run without the observability stack
- Example: `./deploy.sh up prod disable-monitoring`

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

The backend exposes Prometheus-compatible metrics at `/api/v1/metrics`:

```bash
# Fetch metrics
curl http://localhost:8000/api/v1/metrics
```

**Available metrics:**

| Metric | Type | Description |
|--------|------|-------------|
| `http_requests_total` | counter | Total HTTP requests by method, endpoint, status code |
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
| `daemon_runs_total` | counter | Daemon service runs by status |
| `daemon_run_duration_seconds` | histogram | Daemon run latency |
| `daemon_last_run_timestamp` | gauge | Last successful daemon run |
| `daemon_total_failures` | counter | Daemon task failures |
| `daemon_critical_failures` | counter | Critical task failures |
| `process_cpu_seconds_total` | counter | CPU time consumed |
| `process_resident_memory_bytes` | gauge | RSS memory usage |
| `process_virtual_memory_bytes` | gauge | Virtual memory usage |
| `errors_total` | counter | Errors by type, endpoint, status code |

**Request IDs:** Every request gets a unique `request_id` (UUID) that is included in all log lines, enabling correlation between metrics and logs.

### Logs

```bash
./deploy.sh logs [mode] [service]
```

**Examples:**
```bash
./deploy.sh up prod        # Start prod mode (Docker volumes)
./deploy.sh up prod-nas    # Start prod mode (NAS volumes)
./deploy.sh down prod      # Stop prod mode
./deploy.sh logs prod all  # View prod all logs
./deploy.sh logs dev backend # View dev backend logs only
```

### Backups

```bash
./backup.sh [backup_dir]    # Manual backup (keeps 7 most recent)
crontab -e                  # Add automated backup (see crontab.example)
./restore.sh <backup_file>  # Restore from backup
```

### Systemd Service

```bash
./setup-service.sh          # Interactive setup for systemd service
```

### Environment Validation

```bash
./env-validator.sh          # Validate environment configuration
```

---

## Configuration

### Environment Files

| File                  | Purpose                         |
|-----------------------|---------------------------------|
| `.env`                | Primary config (auto-generated) |
| `.env.example`        | Template for creating `.env`    |
| `.env.prod.example`   | Production environment template |
| `.env.test.example`   | Test environment template       |

**How to set up:**

1. **Development** - Run `./deploy.sh up dev` first; it auto-generates `.env` with interactive prompts
2. **Production** - Copy `.env.prod.example` to `.env.prod` and fill in production values

### Storage Configuration

Production deployments require volume configuration for persistent data. Choose between:

- **Docker volumes** (default, easy): Uses named Docker volumes (`postgresql-prod-data`, `redis-prod-data`, `instance-prod-data`)
- **NAS mounts** (recommended for production): Mount external storage via `docker-compose.prod-nas.yml`

See [Production Deployment Guide](./docs/PRODUCTION_DEPLOYMENT.md#volume-configuration) for details.

**Required Variables:**
- `SESSION_SECRET` - Frontend session signing key (32+ chars)
- `JWT_SECRET_KEY` - JWT signing key (32+ chars)
- `OSU_CLIENT_ID`, `OSU_CLIENT_SECRET` - osu! OAuth credentials
- `ADMIN_USER_IDS` - Comma-separated osu! user IDs
- `POSTGRESQL_PASSWORD` - PostgreSQL password
- `POSTGRESQL_DATABASE` - Database name (default: `graveboards_prod`)

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
