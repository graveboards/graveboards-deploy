#!/usr/bin/env bash

# Graveboards Backup Script
# Creates automated backups of PostgreSQL database, Grafana dashboards, and Alertmanager silences
# Usage: backup.sh [backup_directory]
#   If backup_directory is not provided, defaults to ./backups next to this script.
#   Each backup type is written to its own subdirectory: postgresql/, grafana/, alertmanager/
#
# Backups include:
#   - PostgreSQL database (primary, kept with rotation)
#   - Grafana dashboards and datasources (exported via API)
#   - Alertmanager silences (exported via API)
#
# Note: Prometheus TSDB and Loki data are not backed up by default.
# They are regenerable from the app metrics and Docker logs respectively.
# If retention matters, add separate backups for prometheus-data and loki-data volumes.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${1:-${SCRIPT_DIR}/backups}"
DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="graveboards_${DATE}.sql.gz"
MAX_BACKUPS=7
POSTGRESQL_BACKUP_DIR="${BACKUP_DIR}/postgresql"
GRAFANA_BASE_DIR="${BACKUP_DIR}/grafana"
GRAFANA_BACKUP_DIR="${GRAFANA_BASE_DIR}/grafana_${DATE}"
ALERTMANAGER_BASE_DIR="${BACKUP_DIR}/alertmanager"
ALERTMANAGER_BACKUP_FILE="${ALERTMANAGER_BASE_DIR}/alertmanager-silences_${DATE}.json"

# Colors
ColorInfo="\033[1;36m"
ColorSuccess="\033[1;32m"
ColorError="\033[1;31m"
ColorReset="\033[0m"

write_info() { printf "${ColorInfo}[INFO]${ColorReset} %b\n" "$1"; }
write_success() { printf "${ColorSuccess}[OK]${ColorReset} %b\n" "$1"; }
write_warning() { printf "${ColorReset}[WARN]${ColorReset} %b\n" "$1"; }
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

# Create backup directories
mkdir -p "${POSTGRESQL_BACKUP_DIR}"
mkdir -p "${GRAFANA_BACKUP_DIR}"
mkdir -p "${ALERTMANAGER_BASE_DIR}"

# Get Docker Compose network name dynamically
COMPOSE_NETWORK=$(docker network ls --filter name=graveboards --format "{{.Name}}" 2>/dev/null | head -n1)
if [[ -z "${COMPOSE_NETWORK}" ]]; then
    COMPOSE_NETWORK="graveboards_app"
fi

# =========================
# Backup PostgreSQL
# =========================

write_info "Creating database backup: ${BACKUP_FILE}"
write_info "Backup directory: ${POSTGRESQL_BACKUP_DIR}"

docker run --rm \
    --network "${COMPOSE_NETWORK}" \
    -e PGPASSWORD="${POSTGRESQL_PASSWORD}" \
    postgres:16-alpine \
    pg_dump -h graveboards-postgresql -U postgres -d "${POSTGRESQL_DATABASE}" | gzip > "${POSTGRESQL_BACKUP_DIR}/${BACKUP_FILE}"

write_success "Database backup created: ${POSTGRESQL_BACKUP_DIR}/${BACKUP_FILE}"

# =========================
# Backup Grafana (dashboards + datasources)
# =========================

write_info "Backing up Grafana dashboards and datasources..."

GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"

# Export datasources
docker run --rm \
    --user root \
    --network "${COMPOSE_NETWORK}" \
    -v "${GRAFANA_BACKUP_DIR}:/backup" \
    curlimages/curl:latest \
    sh -c "curl -sf -u ${GRAFANA_USER}:${GRAFANA_PASS} http://graveboards-grafana:3000/api/datasources > /backup/datasources.json" && \
    write_success "Grafana datasources exported" || \
    write_warning "Could not export Grafana datasources (Grafana may not be running)"

# Export folders
docker run --rm \
    --user root \
    --network "${COMPOSE_NETWORK}" \
    -v "${GRAFANA_BACKUP_DIR}:/backup" \
    curlimages/curl:latest \
    sh -c "curl -sf -u ${GRAFANA_USER}:${GRAFANA_PASS} http://graveboards-grafana:3000/api/folders > /backup/folders.json" && \
    write_success "Grafana folders exported" || \
    write_warning "Could not export Grafana folders (Grafana may not be running)"

# Export dashboards (search all)
docker run --rm \
    --user root \
    --network "${COMPOSE_NETWORK}" \
    -v "${GRAFANA_BACKUP_DIR}:/backup" \
    curlimages/curl:latest \
    sh -c "curl -sf -u ${GRAFANA_USER}:${GRAFANA_PASS} 'http://graveboards-grafana:3000/api/search?limit=1000' > /backup/dashboards-search.json" && \
    write_success "Grafana dashboard index exported" || \
    write_warning "Could not export Grafana dashboard index (Grafana may not be running)"

# =========================
# Backup Alertmanager silences
# =========================

write_info "Backing up Alertmanager silences..."

docker run --rm \
    --user root \
    --network "${COMPOSE_NETWORK}" \
    -v "${ALERTMANAGER_BASE_DIR}:/backup" \
    curlimages/curl:latest \
    sh -c "curl -sf http://graveboards-alertmanager:9093/api/v2/silences > /backup/$(basename "${ALERTMANAGER_BACKUP_FILE}")" && \
    write_success "Alertmanager silences exported" || \
    write_warning "Could not export Alertmanager silences (Alertmanager may not be running)"

# =========================
# Cleanup: keep only the most recent MAX_BACKUPS database backups
# =========================

write_info "Keeping only the most recent ${MAX_BACKUPS} database backups..."

old_backups=()
while IFS= read -r line; do
    old_backups+=("$line")
done < <(ls -1t "${POSTGRESQL_BACKUP_DIR}"/graveboards_*.sql.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))

if [[ ${#old_backups[@]} -gt 0 ]]; then
    for old_backup in "${old_backups[@]}"; do
        write_info "Removing old backup: $(basename "${old_backup}")"
        rm -f "${old_backup}"
    done
    write_success "Removed ${#old_backups[@]} old backup(s), ${MAX_BACKUPS} kept"
else
    write_info "No old backups to clean up"
fi

# =========================
# Cleanup old Grafana/Alertmanager backups (keep last 7)
# =========================

write_info "Keeping only the most recent ${MAX_BACKUPS} Grafana/Alertmanager backups..."

old_grafana=()
while IFS= read -r line; do
    old_grafana+=("$line")
done < <(ls -1dt "${GRAFANA_BASE_DIR}"/grafana_*/ 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))

if [[ ${#old_grafana[@]} -gt 0 ]]; then
    for old in "${old_grafana[@]}"; do
        write_info "Removing old Grafana backup: $(basename "${old}")"
        rm -rf "${old}"
    done
fi

old_am=()
while IFS= read -r line; do
    old_am+=("$line")
done < <(ls -1t "${ALERTMANAGER_BASE_DIR}"/alertmanager-silences_*.json 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))

if [[ ${#old_am[@]} -gt 0 ]]; then
    for old in "${old_am[@]}"; do
        write_info "Removing old Alertmanager backup: $(basename "${old}")"
        rm -f "${old}"
    done
fi

# =========================
# Verification
# =========================

if [[ -f "${POSTGRESQL_BACKUP_DIR}/${BACKUP_FILE}" ]]; then
    write_success "Backup verification passed"
    ls -lh "${POSTGRESQL_BACKUP_DIR}/${BACKUP_FILE}"
else
    write_error "Backup verification failed"
    exit 1
fi
