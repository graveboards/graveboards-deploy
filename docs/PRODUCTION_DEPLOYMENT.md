# Production Deployment Guide for Graveboards

## Overview

This guide provides step-by-step instructions for deploying Graveboards in a production environment using Docker Compose with Traefik as a reverse proxy for HTTPS.

## Prerequisites

### Hardware Requirements
- **Minimum**: 4 vCPU, 8GB RAM, 50GB disk
- **Recommended**: 8 vCPU, 16GB RAM, 100GB disk
- **CPU**: 64-bit x86 or ARM64
- **OS**: Ubuntu 22.04+ or Debian 12+

### Software Requirements
- Docker Engine 24+
- Docker Compose 2.0+
- `git` for repository management

## Deployment Steps

### 1. Clone Repositories

```bash
# Create workspace
mkdir -p ~/graveboards
cd ~/graveboards

# Clone all repositories
git clone https://github.com/graveboards/graveboards-frontend.git
git clone https://github.com/graveboards/graveboards-backend.git
git clone https://github.com/graveboards/graveboards-deploy.git
```

### 2. Configure Environment

```bash
cd ~/graveboards/graveboards-deploy

# Create .env from template
cp .env.prod.example .env

# Edit .env with production values
vim .env
```

**Required Production Environment Variables:**

```env
# Security (MUST be changed from defaults)
SESSION_SECRET=<generate-with-openssl-rand-base64-32>
JWT_SECRET_KEY=<generate-with-openssl-rand-base64-32>
POSTGRESQL_PASSWORD=<generate-with-openssl-rand-base64-32>

# Mode settings
ENV=prod
DEBUG=false
DISABLE_SECURITY=false

# Database
POSTGRESQL_DATABASE=graveboards_prod

# osu! API credentials
OSU_CLIENT_ID=<your-client-id>
OSU_CLIENT_SECRET=<your-client-secret>

# Base URL (your domain)
BASE_URL=https://graveboards.example.com

```

### Monitoring Configuration (prod required)

```env
# Grafana admin credentials (password must not be a default value)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<strong-password>
GRAFANA_ROOT_URL=https://grafana.graveboards.net

# Alertmanager Discord webhook (required for alerts)
ALERTMANAGER_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN
```

A DNS `A` record for `grafana.graveboards.net` pointing to your server is required.

### Volume Configuration

Graveboards supports two storage modes for production data:

#### Option A: Docker Named Volumes (Default, Easy)

For quick setups or development testing, use Docker named volumes (no configuration needed):

The default configuration uses:
- `postgresql-prod-data` - PostgreSQL data
- `redis-prod-data` - Redis data
- `instance-prod-data` - Backend instance (uploads, logs)

#### Option B: NAS Mounts (Production, Recommended)

For production deployments, mount external storage (like a NAS) to persist data:

**Step 1: Mount NAS to your server**

```bash
# Create mount point
sudo mkdir -p /mnt/nas/graveboards

# Mount NAS (example for NFS)
sudo mount -t nfs your-nas-ip:/path/to/share /mnt/nas/graveboards

# Or for CIFS/SMB
sudo mount -t cifs //your-nas-ip/share /mnt/nas/graveboards -o credentials=/etc/nas-credentials

# Make mount permanent
echo "your-nas-ip:/path/to/share /mnt/nas/graveboards nfs defaults 0 0" | sudo tee -a /etc/fstab
```

**Step 2: Configure volume paths in `.env`**

```env
# Data paths (absolute paths to NAS mount)
POSTGRESQL_DATA_PATH=/mnt/nas/graveboards/postgresql
REDIS_DATA_PATH=/mnt/nas/graveboards/redis
INSTANCE_DATA_PATH=/mnt/nas/graveboards/instance
```

**Step 3: Ensure proper permissions**

```bash
# Docker needs access to the mounted directories
sudo chown -R $USER:$USER /mnt/nas/graveboards
```

**Step 4: Deploy with NAS override**

```bash
./deploy.sh build prod
./deploy.sh up prod --nas
```

**Generate secure secrets:**

```bash
openssl rand -base64 32
```

### 3. Validate Configuration

```bash
# Run environment validator
chmod +x env-validator.sh
./env-validator.sh
```

The validator checks required variables, monitoring secrets (in prod), and compose file existence.

### 4. Build and Deploy

**Using Docker Volumes (Default):**

```bash
# Build all images (uses multi-stage Dockerfile)
./deploy.sh build prod

# Start services
./deploy.sh up prod
```

**Using NAS Volumes (Production):**

```bash
./deploy.sh build prod
./deploy.sh up prod --nas
```

### HTTPS with Traefik

For automatic TLS via Let's Encrypt on both the frontend and Grafana:

```bash
# 1. Update domains in docker-compose.prod.traefik.yml
vim docker-compose.prod.traefik.yml

# 2. Start with Traefik
./deploy.sh up prod --traefik
```

The Traefik configuration provides:
- Automatic TLS certificate provisioning (Let's Encrypt) for `graveboards.net` and `grafana.graveboards.net`
- Security headers (HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy)
- Rate limiting (10 requests/second)
- WebSocket support
- HTTP-to-HTTPS redirect

### Docker Multi-Stage Build

The frontend Dockerfile has four stages: `deps`, `builder`, `development`, and `production`. Only the last two are used as build targets:

- **development** - Full Node.js environment with hot-reload (`npm run dev`)
- **production** - Optimized for production with standalone output (`next start`)

Build targets are automatically selected based on mode:
- Dev mode: `--target development`
- Prod mode: `--target production`

You can also build directly:
```bash
docker build --target development -t frontend:dev graveboards-frontend/
docker build --target production -t frontend:latest graveboards-frontend/
```

### 5. Verify Deployment

```bash
# Check service status
./deploy.sh status

# View logs
./deploy.sh logs prod all

# Test health endpoint
curl -f http://localhost:8000/api/v1/health

# Test frontend
curl -f http://localhost:3000
```

## Security Hardening

### 1. Enable HTTPS with Traefik (Recommended)

Configure `docker-compose.prod.traefik.yml` with your domains:

```yaml
# In docker-compose.prod.traefik.yml, set:
# traefik.http.routers.graveboards-frontend.rule=Host(`graveboards.example.com`)
# traefik.http.routers.graveboards-grafana.rule=Host(`grafana.example.com`)
```

Traefik handles Let's Encrypt certificate provisioning automatically. No manual certbot setup required.

### 2. Secure Docker

Create a dedicated user:

```bash
sudo useradd -r -s /bin/false graveboards
sudo usermod -aG docker graveboards
```

Set proper permissions:

```bash
sudo chown -R graveboards:graveboards ~/graveboards
```

### 3. Enable Automatic Updates

```bash
# Enable unattended upgrades
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

## Monitoring and Logging

### Architecture

The monitoring stack runs **internal-only** in production (no host ports published):

```
Frontend (grafana.graveboards.net via Traefik, TLS + auth)
    │
    ├─► Grafana (public, authenticated)
    │       ├─► Prometheus (internal datasource)
    │       └─► Loki (internal datasource)
    │
Backend (/metrics, internal only, single scrape target)
    │
    ├─► Prometheus (scrapes backend + exporters)
    ├─► Alertmanager (native discord_configs)
    ├─► Loki (stores logs shipped by Promtail)
    ├─► Promtail (ships Docker json-file logs to Loki)
    ├─► node-exporter (host metrics)
    ├─► postgres-exporter (DB metrics)
    └─► redis-exporter (Redis metrics)
```

Only Grafana is publicly reachable. Prometheus, Loki, Alertmanager, and exporters are internal-only, accessible via Grafana datasources or SSH tunnels.

### Health Checks

The deployment includes automatic health checks:

- Backend: `/api/v1/health` (every 60s)
- PostgreSQL: `pg_isready` (every 10s)
- Redis: `redis-cli ping` (every 10s)

### Logs

View logs:

```bash
# All services
./deploy.sh logs prod all

# Specific service
./deploy.sh logs prod backend
./deploy.sh logs prod frontend
./deploy.sh logs prod postgresql
./deploy.sh logs prod redis

# Follow logs
./deploy.sh logs prod backend -f
```

**Log format:** the backend always writes clean colored lines to stdout (`docker compose logs`) and structured JSON to `instance/logs/app.jsonl`, which promtail tails — no env var needed. Every line includes `request_id` when a request is in flight, for correlation with Loki.

Query Loki from Grafana Explore:
```logql
{service="backend", level="error"} | json | request_id="your-request-id"
```

### Monitoring Configuration

`monitoring/prometheus/alerts.yml` defines alerting rules for:
- Service down (5m critical)
- High latency (2000ms warning)
- Database connection loss (1m critical)
- Redis down (via redis-exporter, 1m critical)
- High error rate (>5% warning)
- All scrape targets down (`up == 0`)

Alerts are delivered to Discord via native `discord_configs`.

## Backups

### What Gets Backed Up

The `backup.sh` script backs up:
- **PostgreSQL database** (primary, rotated: 7 most recent)
- **Grafana dashboards and datasources** (exported via API)
- **Alertmanager silences** (exported via API)

**Not backed up by default:** Prometheus TSDB and Loki data are regenerable from app metrics and Docker logs. If retention matters, back up `prometheus-data` and `loki-data` volumes separately.

### Manual Backup

```bash
cd ~/graveboards/graveboards-deploy

# Default: stores in ./backups next to this script
./backup.sh

# Or specify a custom backup directory
./backup.sh /path/to/backups
```

### Automated Backup (Cron)

See `crontab.example` for a ready-to-use cron configuration:

```bash
crontab -e

# Daily backup at 2:00 AM
0 2 * * * /path/to/graveboards-deploy/backup.sh /path/to/backups >> /var/log/graveboards-backup.log 2>&1
```

### Restore from Backup

```bash
cd ~/graveboards/graveboards-deploy

# Restore from a backup file (supports relative or absolute paths)
./restore.sh backups/graveboards_2026-07-06_22-30-45.sql.gz --yes
```

The restore process will:
1. Prompt for confirmation (use `--yes` to skip)
2. Stop all services
3. Restore the database
4. Restart services

## Systemd Service

For automatic startup on boot, use the interactive service generator:

```bash
./setup-service.sh
```

This script will:
1. Select compose configuration (prod, prod-nas, prod-traefik)
2. Optionally enable the monitoring stack
3. Configure environment variables
4. Choose between system-wide (sudo) or user-level systemd
5. Generate and install the service file
6. Optionally enable on boot and start the service

### Service Management

```bash
# System-wide
sudo systemctl start graveboards
sudo systemctl stop graveboards
sudo systemctl restart graveboards
sudo systemctl status graveboards
sudo journalctl -u graveboards -f

# User-level
systemctl --user start graveboards
systemctl --user stop graveboards
systemctl --user restart graveboards
systemctl --user status graveboards
journalctl --user -u graveboards -f
```

**Note:** For container logs, use `docker compose logs` instead of journalctl, since the systemd service is a oneshot wrapper that starts the containers.

## Maintenance

### Update Deployment

```bash
cd ~/graveboards/graveboards-deploy

# Pull latest changes
git pull

# Rebuild images
./deploy.sh build prod

# Restart services (using same volume mode)
./deploy.sh down prod
./deploy.sh up prod
```

**For NAS deployments:**

```bash
./deploy.sh down prod --nas
./deploy.sh up prod --nas
```

### View Service Status

```bash
./deploy.sh status
```

### Restart Services

```bash
./deploy.sh down prod
./deploy.sh up prod
```

### View Logs

```bash
./deploy.sh logs prod [backend|frontend|postgresql|redis|all]
```

**Examples:**
```bash
./deploy.sh logs prod all      # View prod all logs
./deploy.sh logs prod backend  # View prod backend logs only
./deploy.sh logs prod postgresql # View prod postgres logs
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs (specify mode and service if needed)
./deploy.sh logs prod
./deploy.sh logs prod backend

# Check container status
docker ps -a --filter "name=graveboards"

# Inspect container
docker inspect graveboards-backend
```

### Database Connection Issues

```bash
# Check PostgreSQL
docker exec -it graveboards-postgresql pg_isready

# Check database exists
docker exec -it graveboards-postgresql psql -U postgres -c "\l" | grep graveboards_prod
```

### Redis Connection Issues

```bash
# Check Redis
docker exec -it graveboards-redis redis-cli ping

# Check Redis database
docker exec -it graveboards-redis redis-cli DBSIZE
```

### Frontend Build Errors

```bash
# Clear frontend cache
rm -rf graveboards-frontend/.next

# Rebuild with target
./deploy.sh build prod

# Or direct Docker build:
docker build --target production -t frontend:latest graveboards-frontend/
```

### Backend Runtime Errors

```bash
# Check environment
docker compose -f docker-compose.prod.yml exec backend python -m manage status

# Verify config
grep -E "^(JWT_SECRET_KEY|POSTGRESQL|REDIS)" .env
```

## Scaling

### Horizontal Scaling

For higher traffic, consider:

1. **Database Read Replicas**: Add PostgreSQL read replicas for load balancing
2. **Load Balancer**: Use Traefik or HAProxy for frontend load balancing
3. **Multiple Backend Instances**: Run multiple backend containers behind load balancer

**Important:** The backend uses a single `prometheus_client` registry in-process. If multi-worker is ever needed, switch to `prometheus_client` multiprocess mode or a sidecar exporter — do not silently add `--workers`.

### Vertical Scaling

Adjust resource limits in `docker-compose.prod.yml`:

```yaml
backend:
  deploy:
    resources:
      limits:
        cpus: '4'
        memory: 8G
```

## Security Checklist

- [ ] Changed all default secrets (SESSION_SECRET, JWT_SECRET_KEY, POSTGRESQL_PASSWORD)
- [ ] Set a strong `GRAFANA_ADMIN_PASSWORD` (not a default value)
- [ ] Set `ALERTMANAGER_DISCORD_WEBHOOK_URL` for alerts
- [ ] Enabled HTTPS with Traefik (valid certificate auto-provisioned)
- [ ] Disabled DEBUG mode
- [ ] Disabled DISABLE_SECURITY
- [ ] Set up Traefik with your domain in `docker-compose.prod.traefik.yml`
- [ ] Set up automatic backups
- [ ] Enabled health checks
- [ ] Created monitoring alerts (see `monitoring/prometheus/alerts.yml`)
- [ ] Updated osu! API callback URL
- [ ] Set up rate limiting (configured in Traefik, 10 req/s)
- [ ] Configured CORS headers
- [ ] Verified no monitoring host ports are exposed in production

## Support

For issues or questions:
- Check logs: `./deploy.sh logs prod`
- Run diagnostics: `./env-validator.sh`
- Review documentation in `docs/` subdirectories

## Next Steps

After successful deployment:

1. Configure DNS to point to your server
2. Set up Traefik with your domain (see HTTPS section above)
3. Verify Grafana is accessible at `https://grafana.graveboards.net`
4. Test OAuth flow
5. Create first user account
6. Set up regular backups
7. Test Discord alert delivery
