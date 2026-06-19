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

# Required variables by file
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
    
    # Required variables for backend
    local required_vars=(
        "JWT_SECRET_KEY"
        "POSTGRESQL_HOST"
        "POSTGRESQL_PORT"
        "POSTGRESQL_USERNAME"
        "POSTGRESQL_PASSWORD"
        "POSTGRESQL_DATABASE"
        "REDIS_HOST"
        "REDIS_PORT"
    )
    
    # Check each required variable
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            write_error "Missing required variable: $var"
            return 1
        fi
    done
    
    # Validate JWT_SECRET_KEY length (must be 32+ characters)
    if [[ ${#JWT_SECRET_KEY} -lt 32 ]]; then
        write_error "JWT_SECRET_KEY must be at least 32 characters (currently ${#JWT_SECRET_KEY})"
        return 1
    fi
    

    
    write_success "Environment file validation passed: $file"
    return 0
}

validate_compose_file() {
    local compose_file="$1"
    
    if [[ ! -f "$compose_file" ]]; then
        write_error "Compose file not found: $compose_file"
        return 1
    fi
    
    write_info "Validating compose file: $compose_file"
    
    # Check for common issues
    if grep -q 'POSTGRES_PASSWORD=' "$compose_file" 2>/dev/null; then
        write_warning "Found hardcoded POSTGRES_PASSWORD in compose file (should use secrets or env file)"
    fi
    
    if grep -q 'image: postgres' "$compose_file" 2>/dev/null; then
        write_info "PostgreSQL image found"
    fi
    
    if grep -q 'image: redis' "$compose_file" 2>/dev/null; then
        write_info "Redis image found"
    fi
    
    write_success "Compose file validation passed: $compose_file"
    return 0
}

validate_backend() {
    local backend_dir="$SCRIPT_DIR/../graveboards-backend"
    local env_file="$backend_dir/.env"
    local env_example="$backend_dir/.env.example"
    
    write_info "=== Backend Validation ==="
    
    # Check .env file
    if [[ -f "$env_file" ]]; then
        validate_env_file "$env_file" "deploy"
    else
        write_warning "Deploy .env file not found (first run - will be auto-generated)"
    fi
    
    # Validate SESSION_SECRET for frontend (not required in backend .env)
    local session_secret=""
    if [[ -n "${SESSION_SECRET:-}" ]]; then
        session_secret="$SESSION_SECRET"
    fi
    
    # For backend env files, SESSION_SECRET might not be set
    # Skip validation if it's a backend .env file (no SESSION_SECRET)
    if [[ -z "$session_secret" ]] && [[ "$mode" != "deploy" ]]; then
        write_success "Environment file validation passed: $file"
        return 0
    fi
    
    # Check Dockerfile exists
    if [[ ! -f "$backend_dir/Dockerfile" ]]; then
        write_error "Backend Dockerfile not found"
        exit 1
    fi
    write_success "Backend Dockerfile found"
    
    # Check requirements.txt
    if [[ ! -f "$backend_dir/requirements.txt" ]]; then
        write_error "Backend requirements.txt not found"
        exit 1
    fi
    write_success "Backend requirements.txt found"
}

validate_frontend() {
    local frontend_dir="$SCRIPT_DIR/../graveboards-frontend"
    local env_local="$frontend_dir/.env.local"
    local env_example="$frontend_dir/.env.local.example"
    
    write_info "=== Frontend Validation ==="
    
    # Check .env.local file
    if [[ -f "$env_local" ]]; then
        validate_env_file "$env_local" "frontend"
    else
        write_warning "Frontend .env.local file not found, using .env.local.example as template"
        # Don't fail on missing .env.local (it's gitignored)
    fi
    
    # Check package.json
    if [[ ! -f "$frontend_dir/package.json" ]]; then
        write_error "Frontend package.json not found"
        exit 1
    fi
    write_success "Frontend package.json found"
    
    # Check next.config.ts
    if [[ ! -f "$frontend_dir/next.config.ts" ]]; then
        write_error "Frontend next.config.ts not found"
        exit 1
    fi
    write_success "Frontend next.config.ts found"
    
    # Check frontend health endpoint
    if [[ ! -f "$frontend_dir/src/app/api/health/route.ts" ]]; then
        write_error "Frontend health endpoint not found at src/app/api/health/route.ts"
        exit 1
    fi
    write_success "Frontend health endpoint found"
    
    # Check Dockerfile
    if [[ ! -f "$frontend_dir/Dockerfile" ]]; then
        write_error "Frontend Dockerfile not found"
        exit 1
    fi
    write_success "Frontend Dockerfile found"
}

validate_deploy() {
    local deploy_dir="$SCRIPT_DIR"
    local compose_files=(
        "$deploy_dir/docker-compose.yml"
        "$deploy_dir/docker-compose.prod.yml"
        "$deploy_dir/docker-compose.test.yml"
    )
    
    write_info "=== Deploy Validation ==="
    
    # Check .env file
    local env_file="$deploy_dir/.env"
    if [[ -f "$env_file" ]]; then
        validate_env_file "$env_file" "deploy"
    else
        write_warning "Deploy .env file not found (this is OK for the first run)"
    fi
    
    # Validate compose files
    for compose_file in "${compose_files[@]}"; do
        validate_compose_file "$compose_file" || exit 1
    done
    
    # Check deploy.sh
    if [[ ! -f "$deploy_dir/deploy.sh" ]]; then
        write_error "Deploy script (deploy.sh) not found"
        exit 1
    fi
    write_success "Deploy script found"
    
    # Check deploy.ps1 (Windows)
    if [[ -f "$deploy_dir/deploy.ps1" ]]; then
        write_success "Windows deploy script found"
    else
        write_warning "Windows deploy script (deploy.ps1) not found"
    fi
}

check_docker() {
    write_info "=== Docker Validation ==="
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        write_error "Docker is not installed"
        echo "Please install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    write_success "Docker is installed"
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        write_error "Docker daemon is not running"
        echo "Please start Docker"
        exit 1
    fi
    write_success "Docker daemon is running"
    
    # Check Docker Compose
    if ! docker compose version &> /dev/null; then
        write_error "Docker Compose is not available"
        echo "Please upgrade Docker: https://docs.docker.com/compose/"
        exit 1
    fi
    write_success "Docker Compose is available"
}

print_summary() {
    echo
    echo "========================================="
    echo "Environment Validation Summary"
    echo "========================================="
    echo
    echo "✓ Backend   : Validated"
    echo "✓ Frontend  : Validated"
    echo "✓ Deploy    : Validated"
    echo "✓ Docker    : Validated"
    echo
    write_success "All validations passed!"
    echo
    echo "You can now start the services with:"
    echo "  cd $SCRIPT_DIR"
    echo "  ./deploy.sh up dev"
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
    
    print_summary
}

main "$@"
