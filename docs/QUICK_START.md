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
- Create `.env` files with auto-generated secrets
- Start all services (PostgreSQL, Redis, Backend, Frontend)
- Provide configuration for local development
- Build frontend with hot-reload support

### 3. Verify Installation

```bash
# Check status
./deploy.sh status

# Test health endpoints
curl http://localhost:8000/api/v1/health
curl http://localhost:3000
```

### 4. Development Commands

```bash
# Stop services
./deploy.sh down

# View logs
./deploy.sh logs [dev|prod|test] [service]

# Restart
./deploy.sh up dev
```

### 5. Docker Build Options

The frontend uses a multi-stage Dockerfile with two stages:

- **development** - Full Node.js environment with `npm run dev` (hot-reload)
- **production** - Optimized image with static output (standalone mode)

```bash
# Build development image
./deploy.sh build dev

# Build production image
./deploy.sh build prod

# Direct Docker builds:
docker build --target development -t myapp:dev .
docker build --target production -t myapp:latest .
```

---

## For Production Deployment

### 1. Prerequisites

- Server with Docker Engine 24+
- 4GB+ RAM recommended
- Domain name (for HTTPS)

### 2. Clone and Setup

```bash
git clone https://github.com/graveboards/graveboards-frontend.git
git clone https://github.com/graveboards/graveboards-backend.git
git clone https://github.com/graveboards/graveboards-deploy.git

cd graveboards-deploy
```

### 3. Configure Environment

```bash
# Create .env file (interactive setup)
./deploy.sh up dev

# Or manually create .env with production values
cp .env.example .env
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
```

### 4. Validate Configuration

```bash
./env-validator.sh
```

### 5. Deploy to Production

```bash
./deploy.sh build prod
./deploy.sh up prod
```

### 6. Set Up HTTPS (Recommended)

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Get certificate
sudo certbot --nginx -d your-domain.com
```

### 7. Set Up Backups

```bash
# Test backup
./backup.sh

# Add to crontab for automated backups
crontab -e
# Add: 0 2 * * * cd ~/graveboards-deploy && ./backup.sh >> /var/log/graveboards-backup.log 2>&1
```

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
./deploy.sh logs [dev|prod|test] [service]
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
docker-compose down -v

# View database status
./deploy.sh shell
# Inside container: python -m manage status
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

### Interactive Shell

**Note:** The `shell` command has been removed. Use Docker Compose directly:

```bash
# Backend shell
docker exec -it graveboards-backend sh

# Frontend shell (in frontend directory)
npm run dev
```

## Next Steps

1. Configure osu! OAuth callback URL
2. Set up domain DNS
3. Configure SSL/TLS
4. Set up monitoring
5. Configure backups
6. Review security checklist in docs/PRODUCTION_DEPLOYMENT.md
