# Production Deployment Guide for Graveboards

## Overview

This guide provides step-by-step instructions for deploying Graveboards in a production environment using Docker Compose.

## Prerequisites

### Hardware Requirements
- **Minimum**: 4 vCPU, 8GB RAM, 50GB disk
- **Recommended**: 8 vCPU, 16GB RAM, 100GB disk
- **CPU**: 64-bit x86 or ARM64
- **OS**: Ubuntu 22.04+ or Debian 12+

### Software Requirements
- Docker Engine 24+
- Docker Compose 2.0+
- Node.js 22+ (for frontend builds, optional)
- Python 3.14+ (for backend development, optional)
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

# Create .env file from template
cp .env.prod.example .env.prod

# Edit .env.prod with production values
vim .env.prod
```

**Required Production Environment Variables:**

```env
# Security (MUST be changed from defaults)
SESSION_SECRET=<generate-with-openssl-rand-base64-32>
JWT_SECRET_KEY=<generate-with-openssl-rand-base64-32>
POSTGRESQL_PASSWORD=<generate-with-openssl-rand-base64-32>

# Mode settings
DEBUG=false
DISABLE_SECURITY=false
ENV=prod

# Database
POSTGRESQL_DATABASE=graveboards_prod

# Admin users (comma-separated osu! user IDs)
ADMIN_USER_IDS=<your-osu-user-id>

# osu! API credentials
OSU_CLIENT_ID=<your-client-id>
OSU_CLIENT_SECRET=<your-client-secret>

# Base URL (your domain)
BASE_URL=https://graveboards.example.com
```

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

**Step 2: Configure volume paths in `.env.prod`**

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

Use the NAS-specific docker-compose configuration:

```bash
# Build images
./deploy.sh build prod

# Start services with NAS volumes
docker-compose -f docker-compose.prod.yml -f docker-compose.prod-nas.yml up -d
```

**Note:** The `docker-compose.prod-nas.yml` file overrides the default volume paths with your NAS configuration. It should be used in combination with `docker-compose.prod.yml` using the `-f` flag.

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
# Build all images
./deploy.sh build prod

# Start services with NAS volumes
docker-compose -f docker-compose.prod.yml -f docker-compose.prod-nas.yml up -d
```

**Note:** For NAS deployments, ensure your `.env.prod` file has the `POSTGRESQL_DATA_PATH`, `REDIS_DATA_PATH`, and `INSTANCE_DATA_PATH` variables set to your NAS mount points (e.g., `/mnt/nas/graveboards/postgresql`).

### Docker Multi-Stage Build

The frontend uses a single multi-stage Dockerfile:

- **development stage** - Full dev environment with hot-reload (`npm run dev`)
- **production stage** - Optimized for production with standalone output

Build targets are automatically selected based on mode:
- Dev mode: `--target development`
- Prod mode: `--target production`

You can also build directly:
```bash
docker build --target development -t frontend:dev .
docker build --target production -t frontend:latest .
```

### 5. Verify Deployment

```bash
# Check service status
./deploy.sh status

# View logs
./deploy.sh logs

# Test health endpoint
curl -f http://localhost:8000/api/v1/health

# Test frontend
curl -f http://localhost:3000
```

## Security Hardening

### 1. Enable HTTPS with Let's Encrypt

Install certbot:

```bash
sudo apt update
sudo apt install certbot python3-certbot-nginx
```

Obtain certificate:

```bash
sudo certbot --nginx -d graveboards.example.com
```

### 2. Configure Firewall

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

### 3. Secure Docker

Create dedicated user:

```bash
sudo useradd -r -s /bin/false graveboards
sudo usermod -aG docker graveboards
```

Set proper permissions:

```bash
sudo chown -R graveboards:graveboards ~/graveboards
```

### 4. Enable Automatic Updates

```bash
# Enable unattended upgrades
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

## Monitoring and Logging

### Health Checks

The deployment includes automatic health checks:

- Backend: `/api/v1/health` (every 30s)
- Frontend: HTTP 200 check (every 30s)
- PostgreSQL: `pg_isready` (every 10s)
- Redis: `redis-cli ping` (every 10s)

### Logs

View logs:

```bash
# All services
./deploy.sh logs [dev|prod|test] all

# Specific service
./deploy.sh logs prod backend
./deploy.sh logs prod frontend
./deploy.sh logs prod postgres
./deploy.sh logs prod redis

# Follow logs
./deploy.sh logs prod backend
```

### Metrics

Metrics are available at `/api/v1/health` (basic) or configured Prometheus endpoint.

## Backups

### Manual Backup

```bash
cd ~/graveboards/graveboards-deploy
chmod +x backup.sh
./backup.sh
```

### Automated Backup (Cron)

Add to crontab:

```bash
crontab -e

# Add: Daily backup at 2:00 AM
0 2 * * * cd ~/graveboards/graveboards-deploy && ./backup.sh >> /var/log/graveboards-backup.log 2>&1
```

### Restore from Backup

```bash
cd ~/graveboards/graveboards-deploy
chmod +x restore.sh
./restore.sh backups/graveboards_backup_YYYYMMDD_HHMMSS.sql.gz --yes
```

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
# Stop services
docker-compose -f docker-compose.prod.yml -f docker-compose.prod-nas.yml down

# Restart with NAS
docker-compose -f docker-compose.prod.yml -f docker-compose.prod-nas.yml up -d
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
./deploy.sh logs prod [backend|frontend|postgres|redis|all]
```

**Examples:**
```bash
./deploy.sh logs prod all      # View prod all logs
./deploy.sh logs prod backend  # View prod backend logs only
./deploy.sh logs prod postgres # View prod postgres logs
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
rm -rf ~/.next
rm -rf graveboards-frontend/.next

# Rebuild with target
./deploy.sh build prod

# Or direct Docker build:
docker build --target production -t frontend:latest graveboards-frontend/
```

### Backend Runtime Errors

```bash
# Check environment
./deploy.sh shell

# Verify config
grep -E "^(JWT_SECRET_KEY|POSTGRES|REDIS)" .env
```

## Scaling

### Horizontal Scaling

For higher traffic, consider:

1. **Database Read Replicas**: Add PostgreSQL read replicas for load balancing
2. **Load Balancer**: Use nginx or HAProxy for frontend load balancing
3. **Multiple Backend Instances**: Run multiple backend containers behind load balancer

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

- [ ] Changed all default secrets
- [ ] Enabled HTTPS with valid certificate
- [ ] Disabled DEBUG mode
- [ ] Disabled DISABLE_SECURITY
- [ ] Configured firewall rules
- [ ] Set up automatic backups
- [ ] Enabled health checks
- [ ] Configured logging
- [ ] Created monitoring alerts
- [ ] Updated osu! API callback URL
- [ ] Set up rate limiting
- [ ] Configured CORS headers

## Support

For issues or questions:
- Check logs: `./deploy.sh logs`
- Run diagnostics: `./env-validator.sh`
- Review documentation in `docs/` subdirectories

## Next Steps

After successful deployment:

1. Configure DNS to point to your server
2. Set up SSL certificate
3. Configure monitoring (optional)
4. Test OAuth flow
5. Create first user account
6. Set up regular backups
7. Configure monitoring and alerting
