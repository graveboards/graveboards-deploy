#!/usr/bin/env bash

# Graveboards Backup Script
# Creates automated backups of PostgreSQL database
# Usage: backup.sh [backup_directory]
#   If backup_directory is not provided, defaults to ./backups next to this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${1:-${SCRIPT_DIR}/backups}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="graveboards_backup_${DATE}.sql.gz"
MAX_BACKUPS=7

# Colors
ColorInfo="\033[1;36m"
ColorSuccess="\033[1;32m"
ColorError="\033[1;31m"
ColorReset="\033[0m"

write_info() { printf "${ColorInfo}[INFO]${ColorReset} %b\n" "$1"; }
write_success() { printf "${ColorSuccess}[OK]${ColorReset} %b\n" "$1"; }
write_error() { printf "${ColorError}[ERROR]${ColorReset} %b\n" "$1"; }

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Required variables
if [[ -z "${POSTGRESQL_PASSWORD}" ]]; then
    write_error "POSTGRESQL_PASSWORD not set in .env"
    exit 1
fi

if [[ -z "${POSTGRESQL_DATABASE}" ]]; then
    write_error "POSTGRESQL_DATABASE not set in .env"
    exit 1
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Get Docker Compose network name dynamically
COMPOSE_NETWORK=$(docker network ls --filter name=graveboards --format "{{.Name}}" 2>/dev/null | head -n1)
if [[ -z "${COMPOSE_NETWORK}" ]]; then
    COMPOSE_NETWORK="graveboards_app"
fi

# Backup command
write_info "Creating backup: ${BACKUP_FILE}"
write_info "Backup directory: ${BACKUP_DIR}"

docker run --rm \
    --network "${COMPOSE_NETWORK}" \
    -e PGPASSWORD="${POSTGRESQL_PASSWORD}" \
    postgres:16-alpine \
    pg_dump -h graveboards-postgresql -U postgres -d "${POSTGRESQL_DATABASE}" | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"

write_success "Backup created: ${BACKUP_DIR}/${BACKUP_FILE}"

# Cleanup: keep only the most recent MAX_BACKUPS files
write_info "Keeping only the most recent ${MAX_BACKUPS} backups..."

ls -1t "${BACKUP_DIR}"/graveboards_backup_*.sql.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read -r old_backup; do
    write_info "Removing old backup: $(basename "${old_backup}")"
    rm -f "${old_backup}"
done

write_success "Old backups cleaned up"

# Verification
if [[ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]]; then
    write_success "Backup verification passed"
    ls -lh "${BACKUP_DIR}/${BACKUP_FILE}"
else
    write_error "Backup verification failed"
    exit 1
fi
