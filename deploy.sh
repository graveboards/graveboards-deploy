#!/usr/bin/env bash

# Graveboards Deployment Script for Linux/Mac
# Usage: ./deploy.sh [command] [mode] [service]
#
# Commands:
#   up [mode]               - Start services (default: dev)
#   down [mode]             - Stop services (default: all)
#   build [mode]            - Build images (default: dev)
#   logs [mode] [service]   - View logs (default: dev all)
#   test                    - Run tests
#   status                  - Show status
#   help                    - Show this help
#   clean                   - Remove volumes and images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_PROCESS_PID=""

cleanup() {
    if [[ -n "$COMPOSE_PROCESS_PID" ]] && kill -0 "$COMPOSE_PROCESS_PID" 2>/dev/null; then
        write_info "Stopping services..."
        docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down >/dev/null 2>&1 || true
        docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" down >/dev/null 2>&1 || true
        docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test down >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

BACKEND_DIR="$SCRIPT_DIR/../graveboards-backend"
FRONTEND_DIR="$SCRIPT_DIR/../graveboards-frontend"

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

# =========================
# Step 1: Auto-generate .env files if they don't exist
# =========================

    generate_env_files() {
    write_info "Environment files not found. Starting interactive setup..."
    echo

    # Generate 32-character random alphanumeric secrets
    JWT_SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    JWT_SECRET_KEY_TEST=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    SESSION_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

    echo "You can set up your osu client credentials here:"
    echo "https://osu.ppy.sh/home/account/edit#oauth"
    echo "Step 1: Click 'New OAuth Application +'"
    echo "Step 2: Use http://localhost:3000/callback as callback URL"
    echo

    read -p "Please paste your OSU_CLIENT_ID: " OSU_CLIENT_ID
    read -p "Please paste your OSU_CLIENT_SECRET: " OSU_CLIENT_SECRET
    echo
    read -p "Enter your osu user ID to add yourself as an admin: " OSU_USER_ID
    echo

    DISABLE_SECURITY="false"
    read -p "Disable security for dev convenience? (y/N): " choice
    case "$choice" in
        y|Y) DISABLE_SECURITY="true" ;;
        *) DISABLE_SECURITY="false" ;;
    esac

    # Create .env for direct Python dev mode (connects to Docker DB/Redis via localhost)
     cat > "$BACKEND_DIR/.env" <<EOF
DEBUG=true
DISABLE_SECURITY=$DISABLE_SECURITY
ENV=dev
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JWT_SECRET_KEY
JWT_ALGORITHM=HS256
ADMIN_USER_IDS=$OSU_USER_ID
OSU_CLIENT_ID=$OSU_CLIENT_ID
OSU_CLIENT_SECRET=$OSU_CLIENT_SECRET
POSTGRESQL_HOST=localhost
POSTGRESQL_PORT=5432
POSTGRESQL_USERNAME=postgres
POSTGRESQL_PASSWORD=postgres
POSTGRESQL_DATABASE=graveboards_dev
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_USERNAME=
REDIS_PASSWORD=
REDIS_DB=0
EOF

    # Create .env.test for test mode (isolated DB/Redis)
    cat > "$BACKEND_DIR/.env.test" <<EOF
DEBUG=true
DISABLE_SECURITY=false
ENV=test
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JWT_SECRET_KEY_TEST
JWT_ALGORITHM=HS256
ADMIN_USER_IDS=1,2
OSU_CLIENT_ID=test-client-id
OSU_CLIENT_SECRET=test-client-secret
POSTGRESQL_HOST=localhost
POSTGRESQL_PORT=5432
POSTGRESQL_USERNAME=postgres
POSTGRESQL_PASSWORD=postgres
POSTGRESQL_DATABASE=graveboards_test
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_USERNAME=
REDIS_PASSWORD=
REDIS_DB=15
EOF

    # Create .env for deploy orchestrator
    cat > "$SCRIPT_DIR/.env" <<EOF
# BACKEND
DEBUG=true
DISABLE_SECURITY=$DISABLE_SECURITY
ENV=dev
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JWT_SECRET_KEY
JWT_ALGORITHM=HS256
ADMIN_USER_IDS=$OSU_USER_ID
OSU_CLIENT_ID=$OSU_CLIENT_ID
OSU_CLIENT_SECRET=$OSU_CLIENT_SECRET
POSTGRESQL_PASSWORD=postgres
POSTGRESQL_HOST=postgres
POSTGRESQL_PORT=5432
POSTGRESQL_USERNAME=postgres
POSTGRESQL_PASSWORD=postgres
POSTGRESQL_DATABASE=graveboards_dev
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_USERNAME=
REDIS_PASSWORD=
REDIS_DB=0

# FRONTEND
NEXT_PUBLIC_API_URL=/api/v1
INTERNAL_API_URL=http://graveboards-backend:8000/api/v1
SESSION_SECRET=$SESSION_SECRET
EOF

    echo
    write_success "[OK] Environment files created:"
    echo "  - $BACKEND_DIR/.env (dev mode with localhost DB/Redis)"
    echo "  - $BACKEND_DIR/.env.test (test mode with isolated DB/Redis)"
    echo "  - $SCRIPT_DIR/.env (deploy orchestrator config)"
    echo
    echo "You have been added to ADMIN_USER_IDS as $OSU_USER_ID."
    echo
}

# Check if .env files exist, generate if not
if [[ ! -f "$BACKEND_DIR/.env" ]] || [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    generate_env_files
fi

# =========================
# Step 2: Check Docker in PATH
# =========================

test_docker_installed() {
    command -v docker >/dev/null 2>&1
}

test_docker_running() {
    docker info >/dev/null 2>&1
}

show_help() {
    cat << EOF
Graveboards Deployment Script for Linux/Mac
Usage: ./deploy.sh [command] [mode] [service]

Commands:
  up [mode]             - Start services (default: dev)
  down [mode]           - Stop services (default: all)
  build [mode]          - Build images (default: dev)
  logs [mode] [service] - View logs (default: dev all)
  test                  - Run tests
  status                - Show status
  clean                 - Remove volumes and images
  help                  - Show this help

Modes:
  dev       - Development mode (default)
  prod      - Production mode (Docker volumes)
  prod-nas  - Production mode (NAS volumes)
  test      - Testing mode

Services:
  all      - All services
  backend  - Backend service
  frontend - Frontend service
  postgres - PostgreSQL database
  redis    - Redis cache

Examples:
  ./deploy.sh up dev            # Start dev mode
  ./deploy.sh up prod           # Start prod mode
  ./deploy.sh down prod         # Stop prod mode
  ./deploy.sh build test        # Build test images
  ./deploy.sh logs dev          # View dev logs (all services)
  ./deploy.sh logs dev backend  # View dev backend logs only
  ./deploy.sh logs prod all     # View prod all logs
  ./deploy.sh logs test backend # View test backend logs only

For more information, see README.md
EOF
}

generate_prod_env() {
    if [[ ! -f "$SCRIPT_DIR/.env.prod" ]] && [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        write_error "Production mode requires .env.prod or .env file with credentials"
        write_warning "Copy .env.prod.example to .env.prod and fill in your values:"
        echo "  cp .env.prod.example .env.prod"
        echo "  vim .env.prod"
        exit 1
    fi
}

start_services() {
    local mode="$1"
    
    write_info "Starting Graveboards in $mode mode..."
    
    case "$mode" in
        dev)
            docker-compose -f "$SCRIPT_DIR/docker-compose.yml" up --build &
            COMPOSE_PROCESS_PID=$!
            wait $COMPOSE_PROCESS_PID
            ;;
        prod)
            generate_prod_env
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" up --build &
            COMPOSE_PROCESS_PID=$!
            wait $COMPOSE_PROCESS_PID
            ;;
        prod-nas)
            generate_prod_env
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" -f "$SCRIPT_DIR/docker-compose.prod-nas.yml" up --build &
            COMPOSE_PROCESS_PID=$!
            wait $COMPOSE_PROCESS_PID
            ;;
        test)
            docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" up --profile test --build &
            COMPOSE_PROCESS_PID=$!
            wait $COMPOSE_PROCESS_PID
            ;;
    esac
}

stop_services() {
    local mode="$1"
    
    write_info "Stopping Graveboards services..."
    
    case "$mode" in
        all)
            docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" down
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod-nas.yml" down
            docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test down
            ;;
        dev)
            docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down
            ;;
        prod)
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" down
            ;;
        prod-nas)
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" -f "$SCRIPT_DIR/docker-compose.prod-nas.yml" down
            ;;
        test)
            docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test down
            ;;
    esac
}

build_images() {
    local mode="$1"
    
    write_info "Building Graveboards images for $mode mode..."
    
    case "$mode" in
        dev)
            docker-compose -f "$SCRIPT_DIR/docker-compose.yml" build
            ;;
        prod)
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" build
            ;;
        prod-nas)
            docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" build
            ;;
        test)
            docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test build
            ;;
    esac
}

view_logs() {
    local mode="$1"
    local service="${2:-all}"
    
    case "$mode" in
        dev)
            local compose_file="$SCRIPT_DIR/docker-compose.yml"
            ;;
        prod)
            local compose_file="$SCRIPT_DIR/docker-compose.prod.yml"
            ;;
        prod-nas)
            local compose_file="$SCRIPT_DIR/docker-compose.prod.yml"
            ;;
        test)
            local compose_file="$SCRIPT_DIR/docker-compose.test.yml"
            ;;
        *)
            write_info "Using default dev mode..."
            local compose_file="$SCRIPT_DIR/docker-compose.yml"
            mode="dev"
            ;;
    esac
    
    case "$service" in
        all)
            docker-compose -f "$compose_file" logs -f
            ;;
        backend)
            docker-compose -f "$compose_file" logs -f backend
            ;;
        frontend)
            docker-compose -f "$compose_file" logs -f frontend
            ;;
        postgres|postgresql)
            docker-compose -f "$compose_file" logs -f postgresql
            ;;
        redis)
            docker-compose -f "$compose_file" logs -f redis
            ;;
        *)
            write_info "Service '$service' not found. Showing all logs..."
            docker-compose -f "$compose_file" logs -f
            ;;
    esac
}

run_tests() {
    write_info "Running Graveboards tests..."
    
    # Check if backend directory exists
    if [[ ! -d "$BACKEND_DIR" ]]; then
        write_error "Backend directory not found at $BACKEND_DIR"
        exit 1
    fi
    
    # Check if pytest is available
    if ! command -v pytest >/dev/null 2>&1; then
        write_warning "pytest not found in PATH. Attempting to use Docker..."
        
        # Use Docker to run tests
            docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test run --rm backend
    else
        # Run tests directly
        pushd "$BACKEND_DIR" >/dev/null
        pytest
        popd >/dev/null
    fi
}

show_status() {
    write_info "Graveboards Service Status"
    printf "${ColorInfo}==========================${ColorReset}\n"
    
    printf "\n%s" "Backend Repository:"
    if [[ -d "$BACKEND_DIR" ]]; then
        write_success "Found at $BACKEND_DIR"
    else
        write_error "Not found at $BACKEND_DIR"
    fi
    
    printf "\n%s" "Frontend Repository:"
    if [[ -d "$FRONTEND_DIR" ]]; then
        write_success "Found at $FRONTEND_DIR"
    else
        write_error "Not found at $FRONTEND_DIR"
    fi
    
    printf "\n%s" "Docker:"
    if test_docker_installed; then
        write_success "Docker is installed"
    else
        write_error "Docker is not installed"
    fi
    
    if test_docker_running; then
        write_success "Docker daemon is running"
    else
        write_error "Docker daemon is not running"
    fi
    
    printf "\n%s\n" "Container Status:"
    docker ps -a --filter "name=graveboards" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

clean_environment() {
    write_warning "This will remove all volumes and images! (excluding prod)"
    read -p "Are you sure? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        write_info "Removing volumes and images..."
        docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down -v
        docker-compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test down -v
        docker-compose -f "$SCRIPT_DIR/docker-compose.prod.yml" down

        # Remove images
        docker rmi -f $(docker images -q graveboards* 2>/dev/null) 2>/dev/null || true
        write_success "Cleaned up environment"
    else
        write_info "Clean aborted"
    fi
}

# Main execution
printf "${ColorInfo}Graveboards Deployment Script for Linux/Mac${ColorReset}\n"
printf "${ColorInfo}==========================================${ColorReset}\n\n"

# Check Docker
if ! test_docker_installed; then
    write_error "Docker is not installed"
    write_info "Please install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! test_docker_running; then
    write_error "Docker daemon is not running"
    write_info "Please start Docker"
    exit 1
fi

# Check arguments
if [[ $# -eq 0 ]]; then
    Command="up"
    Mode="dev"
else
    Command="$1"
    shift
    if [[ "$Command" == "logs" ]]; then
        Mode="${1:-all}"
        shift
        Service="$1"
    else
        Mode="${1:-dev}"
    fi
fi

# Execute command
case "$Command" in
    help)
        show_help
        ;;
    up)
        start_services "$Mode"
        ;;
    down)
        stop_services "$Mode"
        ;;
    build)
        build_images "$Mode"
        ;;
    logs)
        view_logs "$Mode" "$Service"
        ;;
    test)
        run_tests
        ;;
    status)
        show_status
        ;;
    clean)
        clean_environment
        ;;
    *)
        write_error "Unknown command: $Command"
        show_help
        exit 1
        ;;
esac

exit 0
