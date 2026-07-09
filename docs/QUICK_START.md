# Quick Start Guide

## For Developers (Local Development)

### 1. Clone and Setup

```bash
# Clone all repositories
git clone https://github.com/graveboards/graveboards-frontend.git
git clone https://github.com/graveboards/graveboards-backend.git
git clone https://github.com/graveboards/graveboards-deploy.git

cd graveboards-deploy
```

### 2. Start Development Environment

```bash
# Interactive setup (generates environment files)
./deploy.sh up dev
```

This will:
- Prompt for osu! OAuth credentials, admin user ID, and optional extra queues/users
- Create `.env` files with auto-generated secrets
- Start all services (PostgreSQL, Redis, Backend, Frontend, monitoring stack)
- Build frontend with hot-reload support

### 3. Access Monitoring (dev)

Monitoring is enabled by default. To access the monitoring UIs locally, publish ports:

```bash
./deploy.sh up dev --monitoring-ports
```

- Grafana: http://localhost:3001 (default: admin / password)
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093
- Loki: http://localhost:3100

### 4. Verify Installation

```bash
# Check status
./deploy.sh status

# Test health endpoints
curl http://localhost:8000/api/v1/health
curl http://localhost:3000
```

### 5. Development Commands

```bash
# Stop services
./deploy.sh down

# View logs
./deploy.sh logs [dev|prod|test] [backend|frontend|postgresql|redis|all]

# Restart
./deploy.sh up dev
```

### 6. Run Tests

```bash
# Via orchestrator (isolated DB/Redis)
./deploy.sh test

# Via backend Makefile
cd graveboards-backend
make test
```

### 7. Docker Build Options

The frontend uses a multi-stage Dockerfile with two main stages:

- **development** - Full Node.js environment with `npm run dev` (hot-reload)
- **production** - Optimized image with standalone output (`next start`)

```bash
# Build development image
./deploy.sh build dev

# Build production image
./deploy.sh build prod

# Direct Docker builds:
docker build --target development -t frontend:dev graveboards-frontend/
docker build --target production -t frontend:latest graveboards-frontend/
```

---

## For Production Deployment

### 1. Prerequisites

- Server with Docker Engine 24+
- 4GB+ RAM recommended
- Domain name (for HTTPS via Traefik)
- DNS `A` record for `grafana.<your-domain>` (for Grafana access)

### 2. Clone and Setup

```bash
git clone https://github.com/graveboards/graveboards-frontend.git
git clone https://github.com/graveboards/graveboards-backend.git
git clone https://github.com/graveboards/graveboards-deploy.git

cd graveboards-deploy
```

### 3. Configure Environment

```bash
# Create .env from prod template
cp .env.prod.example .env

# Edit with production values
vim .env
```

**Important: Change these values for production:**
```env
SESSION_SECRET=<openssl-rand-base64-32>
JWT_SECRET_KEY=<openssl-rand-base64-32>
POSTGRESQL_PASSWORD=<openssl-rand-base64-32>
DEBUG=false
DISABLE_SECURITY=false
BASE_URL=https://your-domain.com
LOG_FORMAT=json
```

**Monitoring (required for prod):**
```env
GRAFANA_ADMIN_PASSWORD=<strong-password>
ALERTMANAGER_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN
GRAFANA_ROOT_URL=https://grafana.your-domain.com
```

### 4. Validate Configuration

```bash
./env-validator.sh
```

### 5. Deploy to Production

```bash
# Build images
./deploy.sh build prod

# Start services (Docker volumes)
./deploy.sh up prod

# Or with NAS volumes
./deploy.sh up prod --nas
```

### 6. Set Up HTTPS with Traefik (Recommended)

Use the Traefik override for automatic Let's Encrypt TLS on both the frontend and Grafana:

```bash
# Update domains in docker-compose.prod.traefik.yml
vim docker-compose.prod.traefik.yml

# Start with Traefik
./deploy.sh up prod --traefik
```

The Traefik configuration includes:
- Automatic TLS certificate provisioning via Let's Encrypt
- Security headers (HSTS, CSP, X-Frame-Options, etc.)
- Rate limiting (10 req/s)
- WebSocket support

### 7. Access Grafana

Grafana is the single public monitoring entry point:

```
https://grafana.graveboards.net
```

Log in with the `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`. From Grafana, explore Prometheus and Loki datasources.

Prometheus, Loki, Alertmanager, and exporters are **internal-only** (no host ports in production).

### 8. Set Up Backups

```bash
# Test backup (defaults: stores in ./backups next to this script)
./backup.sh

# Or specify a custom backup directory
./backup.sh /path/to/backups

# Add to crontab for automated backups (see crontab.example)
crontab -e
# Add: 0 2 * * * /path/to/graveboards-deploy/backup.sh /path/to/backups >> /var/log/graveboards-backup.log 2>&1
```

Backups include PostgreSQL, Grafana dashboards/datasources, and Alertmanager silences.

### 9. Set Up Systemd Service (Optional)

For automatic startup on boot:

```bash
./setup-service.sh
```

This interactive script will:
- Choose compose configuration (prod, prod-nas, prod-traefik)
- Optionally enable the monitoring stack
- Set environment variables
- Choose system-wide or user-level systemd
- Generate and install the service file

## Common Tasks

### Update Deployment

```bash
cd graveboards-deploy
git pull
./deploy.sh build prod
./deploy.sh down prod
./deploy.sh up prod
```

### View Logs

```bash
./deploy.sh logs [dev|prod|test] [backend|frontend|postgresql|redis|all]
```

**Examples:**
```bash
./deploy.sh logs dev          # View dev logs (all services)
./deploy.sh logs dev backend  # View dev backend logs only
./deploy.sh logs prod all     # View prod all logs
./deploy.sh logs test backend # View test backend logs only
```

### Database Management

```bash
# Reset database (dev only!)
./deploy.sh down dev
docker compose -f docker-compose.yml down -v

# View database status
docker compose -f docker-compose.yml exec backend python -m manage status

# Seed database
docker compose -f docker-compose.yml exec backend python -m manage seed all
```

### Interactive Shell

Use Docker Compose directly:

```bash
# Backend shell
docker compose -f docker-compose.yml exec backend sh

# PostgreSQL shell
docker compose -f docker-compose.yml exec postgresql psql -U postgres
```

## Troubleshooting

### Service Won't Start

```bash
# Check logs (specify mode and service if needed)
./deploy.sh logs dev
./deploy.sh logs prod backend

# Check container status
docker ps -a --filter "name=graveboards"
```

### Reset Everything

```bash
cd graveboards-deploy
./deploy.sh clean
```

## Next Steps

1. Configure osu! OAuth callback URL
2. Set up domain DNS pointing to your server
3. Configure Traefik with your domain in `docker-compose.prod.traefik.yml`
4. Verify Grafana at `https://grafana.<your-domain>`
5. Configure backups
6. Review security checklist in docs/PRODUCTION_DEPLOYMENT.md
