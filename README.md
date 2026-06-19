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

---

## Docker Build

This project uses a multi-stage Dockerfile with separate stages for development and production:

- **development** - Full Node.js environment with hot-reload support
- **production** - Optimized image with minified static output

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

## Commands

```bash
cd graveboards-deploy
./deploy.sh up [mode]               # Start services
./deploy.sh down [mode]             # Stop services
./deploy.sh logs [mode] [service]   # View logs
./deploy.sh test                    # Run tests
./deploy.sh build [mode]            # Build images
./deploy.sh status                  # Show status
./deploy.sh clean                   # Remove volumes and images
```

**Modes:**
- `dev`      - Development (default)
- `prod`     - Production (Docker volumes)
- `prod-nas` - Production (NAS volumes)
- `test`     - Testing

**Services:**
- `all` - All services (default)
- `backend` - Backend service
- `frontend` - Frontend service
- `postgres` - PostgreSQL database
- `redis` - Redis cache

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
./backup.sh          # Manual backup
crontab -e          # Add automated backup (see docs/PRODUCTION_DEPLOYMENT.md)
./restore.sh <file> # Restore from backup
```

## Documentation

---

## Configuration

### Environment Files

| File                | Purpose                         |
|---------------------|---------------------------------|
| `.env`              | Primary config                  |
| `.env.example`      | Template for creating `.env`    |
| `.env.prod.example` | Production environment template |
| `.env.test.example` | Test environment template       |

**How to set up:**

1. **Development** - Run `./deploy.sh up dev` first, it auto-generates `.env`
2. **Production** - Copy `.env.prod.example` to `.env.prod` and fill in production values

### Storage Configuration

Production deployments require volume configuration for persistent data. Choose between:

- **Docker volumes** (default, easy): Uses named Docker volumes
- **NAS mounts** (recommended for production): Mount external storage

See [Production Deployment Guide](./docs/PRODUCTION_DEPLOYMENT.md#volume-configuration) for details.

**Required Variables:**
- `SESSION_SECRET` Frontend session signing (32+ chars)
- `JWT_SECRET_KEY` - JWT signing key (32+ chars)
- `OSU_CLIENT_ID`, `OSU_CLIENT_SECRET` - osu! OAuth credentials
- `ADMIN_USER_IDS` - Comma-separated osu! user IDs
- `POSTGRESQL_PASSWORD` - PostgreSQL password
- `POSTGRESQL_DATABASE` - Database name (default: graveboards_prod)

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
