#!/usr/bin/env bash

# Graveboards Restore Script
# Restores PostgreSQL database from backup
# Usage: restore.sh <backup_file> [--yes]
#   backup_file can be a relative path (from current directory) or absolute path.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
ColorInfo="\033[1;36m"
ColorSuccess="\033[1;32m"
ColorError="\033[1;31m"
ColorWarning="\033[1;33m"
ColorReset="\033[0m"

write_info() { printf "${ColorInfo}[INFO]${ColorReset} %b\n" "$1"; }
write_success() { printf "${ColorSuccess}[OK]${ColorReset} %b\n" "$1"; }
write_error() { printf "${ColorError}[ERROR]${ColorReset} %b\n" "$1"; }
write_warning() { printf "${ColorWarning}[WARN]${ColorReset} %b\n" "$1"; }

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Parse arguments
if [[ $# -lt 1 ]]; then
    write_error "Usage: $0 <backup_file> [--yes]"
    echo ""
    echo "Options:"
    echo "  --yes  Bypass confirmation prompt"
    echo ""
    write_info "Example: $0 /path/to/graveboards_2026-07-06_22-30-45.sql.gz --yes"
    exit 1
fi

BACKUP_FILE="$1"
BYPASS_CONFIRM=false

if [[ "$2" == "--yes" ]]; then
    BYPASS_CONFIRM=true
fi

# Resolve backup file path (supports both relative and absolute paths)
if [[ "${BACKUP_FILE}" != /* ]]; then
    BACKUP_FILE="$(pwd)/${BACKUP_FILE}"
fi

# Validate backup file exists
if [[ ! -f "${BACKUP_FILE}" ]]; then
    write_error "Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

# Check if compressed
if [[ "${BACKUP_FILE}" == *.gz ]]; then
    COMPRESSION="gzip"
else
    COMPRESSION="none"
fi

# Get Docker Compose network name dynamically
COMPOSE_NETWORK=$(docker network ls --filter name=graveboards --format "{{.Name}}" 2>/dev/null | head -n1)
if [[ -z "${COMPOSE_NETWORK}" ]]; then
    COMPOSE_NETWORK="graveboards_app"
fi

# The restore needs the postgresql container itself up and reachable, so we
# only stop the services that talk to the database (backend, frontend) and
# leave postgresql/network alone. Taking the whole stack down here would
# remove the very container this script connects to.
APP_SERVICES=(graveboards-backend graveboards-frontend)

if ! docker ps --format "{{.Names}}" | grep -qx "graveboards-postgresql"; then
    write_error "graveboards-postgresql container is not running. Start the stack first (./deploy.sh up)."
    exit 1
fi

write_warning "!!! RESTORING BACKUP WILL OVERWRITE EXISTING DATABASE !!!"
echo ""
echo "Backup file: ${BACKUP_FILE}"
echo "Compression: ${COMPRESSION}"
echo "Database: ${POSTGRESQL_DATABASE}"
echo ""

# Confirm restoration
if [[ "${BYPASS_CONFIRM}" != "true" ]]; then
    read -p "Are you sure you want to restore this backup? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        write_info "Restore cancelled"
        exit 0
    fi
fi

# Stop app services that connect to the database (postgresql stays up)
write_info "Stopping backend/frontend services..."
cd "${SCRIPT_DIR}"
docker stop "${APP_SERVICES[@]}" 2>/dev/null || true

# Restore database
write_info "Restoring database from backup..."

if [[ "${COMPRESSION}" == "gzip" ]]; then
    gunzip -c "${BACKUP_FILE}" | docker run --rm -i --network "${COMPOSE_NETWORK}" \
        -e PGPASSWORD="${POSTGRESQL_PASSWORD}" \
        postgres:16-alpine \
        psql -h graveboards-postgresql -U postgres -d "${POSTGRESQL_DATABASE}"
else
    docker run --rm -i --network "${COMPOSE_NETWORK}" \
        -e PGPASSWORD="${POSTGRESQL_PASSWORD}" \
        postgres:16-alpine \
        psql -h graveboards-postgresql -U postgres -d "${POSTGRESQL_DATABASE}" -f "${BACKUP_FILE}"
fi

write_success "Database restored successfully!"

# Restart the services we stopped
write_info "Restarting backend/frontend services..."
docker start "${APP_SERVICES[@]}" 2>/dev/null || true

write_success "Services restarted!"
write_info "Verify the restoration by checking the service status"
