#!/usr/bin/env bash

# Environment Variables Validation Script
# Validates required environment variables for Graveboards deployment
# Usage: ./env-validator.sh

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

# Required variables for deploy .env
REQUIRED_VARS=(
    "POSTGRESQL_PASSWORD"
    "POSTGRESQL_DATABASE"
    "JWT_SECRET_KEY"
    "SESSION_SECRET"
    "OSU_CLIENT_ID"
    "OSU_CLIENT_SECRET"
    "INTERNAL_API_URL"
    "APP_URL"
)

# Optional but recommended
OPTIONAL_VARS=(
    "DEBUG"
    "DISABLE_SECURITY"
    "BASE_URL"
    "JWT_ALGORITHM"
    "POSTGRESQL_HOST"
    "POSTGRESQL_PORT"
    "POSTGRESQL_USERNAME"
    "REDIS_HOST"
    "REDIS_PORT"
    "REDIS_USERNAME"
    "REDIS_PASSWORD"
    "REDIS_DB"
    "NEXT_PUBLIC_API_URL"
)

# Monitoring variables (required in prod)
MONITORING_REQUIRED_VARS=(
    "GRAFANA_ADMIN_PASSWORD"
    "ALERTMANAGER_DISCORD_WEBHOOK_URL"
)

# Default values that should never be used in production
DEFAULT_GRAFANA_PASSWORDS=(
    "password"
    "admin"
    "changeme"
    "grafana"
)

# NAS volume paths (required only when using prod-nas)
NAS_VARS=(
    "POSTGRESQL_DATA_PATH"
    "REDIS_DATA_PATH"
    "INSTANCE_DATA_PATH"
)

validate_env_file() {
    local file="$1"
    local mode="$2"

    if [[ ! -f "$file" ]]; then
        write_error "Environment file not found: $file"
        return 1
    fi

    write_info "Validating $mode environment file: $file"

    # Source the file to get variables
    set -a
    source "$file"
    set +a

    local has_errors=0

    # Check required variables
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            write_error "Missing required variable: $var"
            has_errors=1
        fi
    done

    # Validate JWT_SECRET_KEY length (must be 32+ characters)
    if [[ -n "${JWT_SECRET_KEY}" ]] && [[ ${#JWT_SECRET_KEY} -lt 32 ]]; then
        write_error "JWT_SECRET_KEY must be at least 32 characters (currently ${#JWT_SECRET_KEY})"
        has_errors=1
    fi

    # Check optional variables
    for var in "${OPTIONAL_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            write_warning "Optional variable not set: $var"
        fi
    done

    if [[ "$has_errors" -eq 0 ]]; then
        write_success "Environment file validation passed: $file"
        return 0
    else
        return 1
    fi
}

validate_nas_vars() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    write_info "Checking NAS volume configuration..."

    set -a
    source "$file"
    set +a

    local has_errors=0
    for var in "${NAS_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            write_warning "NAS variable not set: $var (required for prod-nas)"
            has_errors=1
        fi
    done

    if [[ "$has_errors" -eq 0 ]]; then
        write_success "NAS volume configuration valid"
    fi
}

validate_compose_files() {
    local deploy_dir="$1"
    local mode="$2"
    local compose_files=(
        "$deploy_dir/docker-compose.yml"
        "$deploy_dir/docker-compose.prod.yml"
        "$deploy_dir/docker-compose.test.yml"
    )

    write_info "=== Compose Files ==="

    for compose_file in "${compose_files[@]}"; do
        if [[ -f "$compose_file" ]]; then
            write_success "Found: $(basename "$compose_file")"
        else
            write_warning "Missing: $(basename "$compose_file")"
        fi
    done

    # Monitoring compose files (required for prod)
    local monitoring_files=(
        "$deploy_dir/docker-compose.monitoring.yml"
        "$deploy_dir/docker-compose.monitoring.ports.yml"
        "$deploy_dir/docker-compose.monitoring.traefik.yml"
    )

    if [[ "$mode" == "prod" ]]; then
        for mf in "${monitoring_files[@]}"; do
            if [[ -f "$mf" ]]; then
                write_success "Found: $(basename "$mf")"
            else
                write_error "Missing monitoring compose file: $(basename "$mf")"
                has_errors=1
            fi
        done
    fi
}

validate_monitoring() {
    local file="$1"
    local mode="$2"

    if [[ "$mode" != "prod" ]]; then
        return 0
    fi

    write_info "=== Monitoring (prod) ==="

    set -a
    source "$file"
    set +a

    local has_errors=0

    # Check GRAFANA_ADMIN_PASSWORD is set and not a default value
    if [[ -z "${GRAFANA_ADMIN_PASSWORD}" ]]; then
        write_error "GRAFANA_ADMIN_PASSWORD is not set (required for prod)"
        has_errors=1
    else
        local is_default=false
        for default_pass in "${DEFAULT_GRAFANA_PASSWORDS[@]}"; do
            if [[ "${GRAFANA_ADMIN_PASSWORD}" == "$default_pass" ]]; then
                is_default=true
                break
            fi
        done
        if [[ "$is_default" == "true" ]]; then
            write_error "GRAFANA_ADMIN_PASSWORD is set to a default value — change it for production"
            has_errors=1
        else
            write_success "GRAFANA_ADMIN_PASSWORD is set (non-default)"
        fi
    fi

    # Check ALERTMANAGER_DISCORD_WEBHOOK_URL is set
    if [[ -z "${ALERTMANAGER_DISCORD_WEBHOOK_URL}" ]]; then
        write_error "ALERTMANAGER_DISCORD_WEBHOOK_URL is not set (required for prod alerts)"
        write_warning "Alerts will be silently dropped without a Discord webhook"
        has_errors=1
    else
        if [[ "${ALERTMANAGER_DISCORD_WEBHOOK_URL}" == *"YOUR_WEBHOOK"* ]] || [[ "${ALERTMANAGER_DISCORD_WEBHOOK_URL}" == *"your-webhook"* ]]; then
            write_warning "ALERTMANAGER_DISCORD_WEBHOOK_URL appears to be a placeholder — update before deploying"
        else
            write_success "ALERTMANAGER_DISCORD_WEBHOOK_URL is set"
        fi
    fi

    if [[ "$has_errors" -eq 0 ]]; then
        write_success "Monitoring configuration valid for prod"
        return 0
    else
        return 1
    fi
}

validate_backend() {
    local backend_dir="$SCRIPT_DIR/../graveboards-backend"

    write_info "=== Backend ==="

    if [[ -d "$backend_dir" ]]; then
        write_success "Backend directory found"
    else
        write_error "Backend directory not found: $backend_dir"
        return 1
    fi

    if [[ -f "$backend_dir/Dockerfile" ]]; then
        write_success "Backend Dockerfile found"
    else
        write_error "Backend Dockerfile not found"
        return 1
    fi

    if [[ -f "$backend_dir/requirements.txt" ]]; then
        write_success "Backend requirements.txt found"
    else
        write_warning "Backend requirements.txt not found"
    fi

    if [[ -f "$backend_dir/config/bootstrap.yaml" ]]; then
        write_success "Backend bootstrap.yaml found"
    else
        write_warning "Backend bootstrap.yaml not found (will be auto-generated on first run)"
    fi
}

validate_frontend() {
    local frontend_dir="$SCRIPT_DIR/../graveboards-frontend"

    write_info "=== Frontend ==="

    if [[ -d "$frontend_dir" ]]; then
        write_success "Frontend directory found"
    else
        write_error "Frontend directory not found: $frontend_dir"
        return 1
    fi

    if [[ -f "$frontend_dir/package.json" ]]; then
        write_success "Frontend package.json found"
    else
        write_error "Frontend package.json not found"
        return 1
    fi

    if [[ -f "$frontend_dir/Dockerfile" ]]; then
        write_success "Frontend Dockerfile found"
    else
        write_error "Frontend Dockerfile not found"
        return 1
    fi
}

validate_deploy() {
    local deploy_dir="$SCRIPT_DIR"
    local mode="dev"

    write_info "=== Deploy ==="

    # Detect mode from .env
    if [[ -f "$deploy_dir/.env" ]]; then
        set -a
        source "$deploy_dir/.env"
        set +a
        if [[ -n "${ENV}" ]]; then
            mode="$ENV"
        fi
    fi

    # Check .env file
    local env_file="$deploy_dir/.env"
    if [[ -f "$env_file" ]]; then
        validate_env_file "$env_file" "deploy" || return 1
    else
        write_warning "Deploy .env file not found (will be auto-generated on first run)"
    fi

    # Check deploy script
    if [[ -f "$deploy_dir/deploy.sh" ]]; then
        write_success "Deploy script found"
    else
        write_error "Deploy script (deploy.sh) not found"
        return 1
    fi

    # Check backup/restore scripts
    if [[ -f "$deploy_dir/backup.sh" ]]; then
        write_success "Backup script found"
    else
        write_warning "Backup script not found"
    fi

    if [[ -f "$deploy_dir/restore.sh" ]]; then
        write_success "Restore script found"
    else
        write_warning "Restore script not found"
    fi

    # Check setup-service script
    if [[ -f "$deploy_dir/setup-service.sh" ]]; then
        write_success "Systemd service generator found"
    else
        write_warning "Systemd service generator not found"
    fi

    # Validate monitoring for prod
    if [[ -f "$env_file" ]]; then
        validate_monitoring "$env_file" "$mode" || return 1
    fi
}

check_docker() {
    write_info "=== Docker ==="

    if ! command -v docker &>/dev/null; then
        write_error "Docker is not installed"
        echo "Please install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    write_success "Docker is installed"

    if ! docker info &>/dev/null; then
        write_error "Docker daemon is not running"
        echo "Please start Docker"
        exit 1
    fi
    write_success "Docker daemon is running"

    if docker compose version &>/dev/null; then
        write_success "Docker Compose plugin available"
    elif docker-compose version &>/dev/null; then
        write_success "Docker Compose standalone available"
    else
        write_error "Docker Compose is not available"
        echo "Please upgrade Docker: https://docs.docker.com/compose/"
        exit 1
    fi
}

print_summary() {
    echo
    echo "========================================="
    echo "Environment Validation Summary"
    echo "========================================="
    echo
    write_success "All validations passed!"
    echo
    echo "You can now start the services with:"
    echo "  cd $SCRIPT_DIR"
    echo "  ./deploy.sh up dev"
    echo
    echo "Monitoring access (dev):"
    echo "  Grafana:      http://localhost:3001 (use --monitoring-ports)"
    echo "  Prometheus:   http://localhost:9090 (use --monitoring-ports)"
    echo "  Loki:         http://localhost:3100 (use --monitoring-ports)"
    echo
    echo "Monitoring access (prod):"
    echo "  Grafana:      https://grafana.graveboards.net (TLS + auth)"
    echo "  Other services: internal-only (no host ports)"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "Graveboards Environment Validation"
    echo "========================================="
    echo

    check_docker
    validate_backend
    validate_frontend
    validate_deploy

    # Detect mode for compose file validation
    local mode="dev"
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
        if [[ -n "${ENV}" ]]; then
            mode="$ENV"
        fi
    fi
    validate_compose_files "$SCRIPT_DIR" "$mode"

    # Validate NAS vars if .env has them
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        validate_nas_vars "$SCRIPT_DIR/.env"
    fi

    print_summary
}

main "$@"
