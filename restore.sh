#!/usr/bin/env bash

# Graveboards Restore Script
# Restores PostgreSQL database from backup

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
    echo "Backup files are stored in: backups/"
    echo ""
    echo "Options:"
    echo "  --yes  Bypass confirmation prompt"
    echo ""
    write_info "Example: $0 backups/graveboards_backup_YYYYMMDD_HHMMSS.sql.gz --yes"
    exit 1
fi

BACKUP_FILE="$1"
BYPASS_CONFIRM=false

if [[ "$2" == "--yes" ]]; then
    BYPASS_CONFIRM=true
fi

# Validate backup file exists
if [[ ! -f "${SCRIPT_DIR}/${BACKUP_FILE}" ]]; then
    write_error "Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

# Check if compressed
if [[ "${BACKUP_FILE}" == *.gz ]]; then
    COMPRESSION="gzip"
else
    COMPRESSION="none"
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

# Stop services
write_info "Stopping Graveboards services..."
cd "${SCRIPT_DIR}"
./deploy.sh down

# Restore database
write_info "Restoring database from backup..."

# Decompress if needed
if [[ "${COMPRESSION}" == "gzip" ]]; then
    DECOMPRESSED=$(mktemp)
    gunzip -c "${BACKUP_FILE}" > "${DECOMPRESSED}"
    BACKUP_FILE="${DECOMPRESSED}"
fi

# Restore using Docker
docker run --rm --network graveboards_app \
    -e PGPASSWORD="${POSTGRESQL_PASSWORD}" \
    postgres:16-alpine \
    psql -h graveboards-postgresql -U postgres -d "${POSTGRESQL_DATABASE}" -f /input.sql << EOF
\i ${BACKUP_FILE}
EOF

# Cleanup
if [[ -n "${DECOMPRESSED}" ]]; then
    rm -f "${DECOMPRESSED}"
fi

# Start services
write_info "Starting Graveboards services..."
./deploy.sh up

write_success "Database restored successfully!"
write_info "Verify the restoration by checking the service status"
