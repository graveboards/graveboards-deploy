#!/usr/bin/env bash

# Graveboards Deployment Script
# Usage: ./deploy.sh [command] [args...]
#
# Commands:
#   up [mode] [--follow|-f] [--build] [service...]  - Start services
#   down [mode] [service...]              - Stop services
#   build [mode] [service...]             - Build images
#   pull [repo...]                        - Git pull repositories
#   force-pull [repo...]                  - Force reset repositories to origin
#   deploy [mode] [--follow|-f]           - Full pipeline: down + pull + build + up
#   logs [mode] [service]                 - View logs
#   test                                  - Run tests
#   status                                - Show status
#   clean                                 - Remove volumes and images
#   help                                  - Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Docker Compose command detection
# =========================

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
else
    write_error "Docker Compose is not installed"
    write_info "Install Docker Compose v2: https://docs.docker.com/compose/install/"
    exit 1
fi

# =========================
# Compose wrapper function
# =========================

compose() {
    local mode="$1"
    local noMonitoring="${2:-false}"
    local nas="${3:-false}"
    local traefik="${4:-false}"
    local monitoringPorts="${5:-false}"
    local monitoringTraefik="${6:-false}"
    shift 6 || true
    local compose_files=()

    case "$mode" in
        dev)
            compose_files=("-f" "$SCRIPT_DIR/docker-compose.yml")
            ;;
        prod)
            compose_files=("-f" "$SCRIPT_DIR/docker-compose.prod.yml")
            if [[ "$nas" == "true" ]]; then
                compose_files+=("-f" "$SCRIPT_DIR/docker-compose.prod.nas.yml")
            fi
            if [[ "$traefik" == "true" ]]; then
                compose_files+=("-f" "$SCRIPT_DIR/docker-compose.prod.traefik.yml")
            fi
            ;;
        test)
            compose_files=("-f" "$SCRIPT_DIR/docker-compose.test.yml")
            ;;
        *)
            write_error "Unknown mode: $mode"
            exit 1
            ;;
    esac

    if [[ "$mode" != "test" ]] && [[ "$noMonitoring" != "true" ]]; then
        compose_files+=("-f" "$SCRIPT_DIR/docker-compose.monitoring.yml")
        if [[ "$mode" == "dev" ]] && [[ "$monitoringPorts" == "true" ]]; then
            compose_files+=("-f" "$SCRIPT_DIR/docker-compose.monitoring.ports.yml")
        fi
        if [[ "$monitoringTraefik" == "true" ]]; then
            compose_files+=("-f" "$SCRIPT_DIR/docker-compose.monitoring.traefik.yml")
        fi
    fi

    "${COMPOSE_CMD[@]}" "${compose_files[@]}" "$@"
}

# =========================
# Git helper functions
# =========================

git_pull_repo() {
    local repo="$1"
    write_info "Pulling $(basename "$repo")..."
    (
        cd "$repo"
        git pull --ff-only
    ) || {
        write_error "Failed to pull $(basename "$repo")."
        return 1
    }
    write_success "Updated $(basename "$repo")"
}

git_force_pull_repo() {
    local repo="$1"
    write_info "Force updating $(basename "$repo")..."
    (
        cd "$repo"
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD)
        git fetch origin
        git reset --hard "origin/$branch"
        git clean -fd
    )
    write_success "Force updated $(basename "$repo")"
}

# =========================
# Spec cache cleanup
# =========================

get_spec_cache_path() {
    local instance_data_path
    instance_data_path=$(grep '^INSTANCE_DATA_PATH=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    if [[ -n "$instance_data_path" ]]; then
        echo "$instance_data_path/.spec_cache.pkl"
    fi
}

cleanup_spec_cache() {
    local spec_cache
    spec_cache=$(get_spec_cache_path)
    if [[ -n "$spec_cache" ]] && [[ -f "$spec_cache" ]]; then
        write_info "Deleting spec cache: $spec_cache"
        rm -f "$spec_cache"
    fi
}

# =========================
# Cleanup on exit / Ctrl+C
# =========================

COMPOSE_PROCESS_PID=""

cleanup() {
    if [[ -n "$COMPOSE_PROCESS_PID" ]] && kill -0 "$COMPOSE_PROCESS_PID" 2>/dev/null; then
        write_info "Stopping services..."
        "${COMPOSE_CMD[@]}" -f "$SCRIPT_DIR/docker-compose.yml" \
                             -f "$SCRIPT_DIR/docker-compose.prod.yml" \
                             -f "$SCRIPT_DIR/docker-compose.monitoring.yml" \
                             down --remove-orphans >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

# =========================
# Interactive config generation
# =========================

# Config files this script manages. A file is only ever (re)generated when it is
# missing or empty — an existing, non-empty file is ALWAYS preserved, so running
# against a populated repo (e.g. a configured production .env) never destroys it.
_config_targets() {
    printf '%s\n' \
        "$BACKEND_DIR/config/bootstrap.yaml" \
        "$BACKEND_DIR/config/bootstrap.test.yaml" \
        "$BACKEND_DIR/.env" \
        "$BACKEND_DIR/.env.test" \
        "$SCRIPT_DIR/.env"
}

# A target is "missing" (safe to write) when absent or zero-length.
_needs_content() { [[ ! -s "$1" ]]; }

CREATED_FILES=()
SKIPPED_FILES=()

# Write stdin to $1 only if it is missing/empty; otherwise preserve the existing
# file and discard stdin. Outcome is recorded for the summary. Never fails.
write_config_file() {
    local target="$1"
    if _needs_content "$target"; then
        mkdir -p "$(dirname "$target")"
        cat > "$target"
        CREATED_FILES+=("$target")
    else
        cat > /dev/null
        SKIPPED_FILES+=("$target")
    fi
}

generate_config_files() {
    # Prompt only when at least one managed file is missing; otherwise no-op.
    local target
    local -a missing=()
    while IFS= read -r target; do
        if _needs_content "$target"; then
            missing+=("$target")
        fi
    done < <(_config_targets)

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    CREATED_FILES=()
    SKIPPED_FILES=()

    write_info "Missing configuration detected — starting interactive setup."
    write_info "Existing, non-empty files are preserved; only the gaps are filled."
    echo

    local JWT_SECRET_KEY JWT_SECRET_KEY_TEST SESSION_SECRET
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

    local DISABLE_SECURITY="false"
    read -p "Disable security for dev convenience? (y/N): " choice
    case "$choice" in
        y|Y) DISABLE_SECURITY="true" ;;
        *) DISABLE_SECURITY="false" ;;
    esac

    local MASTER_QUEUE_NAME
    read -p "Master queue name [Graveboards Queue]: " MASTER_QUEUE_NAME
    MASTER_QUEUE_NAME="${MASTER_QUEUE_NAME:-Graveboards Queue}"

    local MASTER_QUEUE_DESCRIPTION
    read -p "Master queue description [Master queue for beatmaps to receive leaderboards]: " MASTER_QUEUE_DESCRIPTION
    MASTER_QUEUE_DESCRIPTION="${MASTER_QUEUE_DESCRIPTION:-Master queue for beatmaps to receive leaderboards}"

    declare -a EXTRA_QUEUE_NAMES
    declare -a EXTRA_QUEUE_DESCRIPTIONS
    declare -a EXTRA_QUEUE_USER_IDS
    local EXTRA_QUEUE_COUNT=0

    read -p "Add extra queues? (y/N): " add_queues
    if [[ "$add_queues" =~ ^[yY]$ ]]; then
        while true; do
            read -p "  Queue name: " q_name
            read -p "  Queue description: " q_desc
            read -p "  Owner user ID: " q_uid

            EXTRA_QUEUE_NAMES[$EXTRA_QUEUE_COUNT]="$q_name"
            EXTRA_QUEUE_DESCRIPTIONS[$EXTRA_QUEUE_COUNT]="$q_desc"
            EXTRA_QUEUE_USER_IDS[$EXTRA_QUEUE_COUNT]="$q_uid"
            EXTRA_QUEUE_COUNT=$((EXTRA_QUEUE_COUNT + 1))

            read -p "  Add another queue? (y/N): " again
            [[ ! "$again" =~ ^[yY]$ ]] && break
        done
    fi

    declare -a EXTRA_ADMIN_IDS
    local EXTRA_ADMIN_COUNT=0

    read -p "Add additional admin users? (y/N): " add_admins
    if [[ "$add_admins" =~ ^[yY]$ ]]; then
        while true; do
            read -p "  osu user ID: " extra_admin_id
            EXTRA_ADMIN_IDS[$EXTRA_ADMIN_COUNT]="$extra_admin_id"
            EXTRA_ADMIN_COUNT=$((EXTRA_ADMIN_COUNT + 1))
            read -p "  Add another admin? (y/N): " again
            [[ ! "$again" =~ ^[yY]$ ]] && break
        done
    fi

    # --- Generate bootstrap.yaml for dev (only if missing) ---
    local bootstrap_yaml
    bootstrap_yaml=$({
        echo "master_queue:"
        echo "  name: \"$MASTER_QUEUE_NAME\""
        echo "  description: \"$MASTER_QUEUE_DESCRIPTION\""
        echo "  user_id: $OSU_USER_ID"

        if [[ $EXTRA_QUEUE_COUNT -gt 0 ]]; then
            echo "extra_queues:"
            for i in $(seq 0 $((EXTRA_QUEUE_COUNT - 1))); do
                echo "  - user_id: ${EXTRA_QUEUE_USER_IDS[$i]}"
                echo "    name: \"${EXTRA_QUEUE_NAMES[$i]}\""
                echo "    description: \"${EXTRA_QUEUE_DESCRIPTIONS[$i]}\""
            done
        else
            echo "extra_queues: []"
        fi

        echo "initial_users:"
        echo "  - user_id: $OSU_USER_ID"
        echo "    roles: [admin]"
        echo "    generate_api_key: true"
        echo "    enable_score_fetcher: true"

        for admin_id in "${EXTRA_ADMIN_IDS[@]}"; do
            echo "  - user_id: $admin_id"
            echo "    roles: [admin]"
            echo "    generate_api_key: true"
            echo "    enable_score_fetcher: true"
        done

        echo "initial_roles:"
        echo "  - admin"
        echo "setup_steps:"
        echo "  - create_database"
        echo "  - seed_roles"
        echo "  - seed_users"
        echo "  - seed_api_keys"
        echo "  - seed_queues"
    })
    write_config_file "$BACKEND_DIR/config/bootstrap.yaml" <<< "$bootstrap_yaml"

    # --- Generate bootstrap.test.yaml (only if missing) ---
    write_config_file "$BACKEND_DIR/config/bootstrap.test.yaml" <<'EOF'
master_queue:
  name: "Graveboards Queue"
  description: "Master queue for beatmaps to receive leaderboards"
  user_id: 1
extra_queues: []
initial_users:
  - user_id: 1
    roles: [admin]
    generate_api_key: true
    enable_score_fetcher: true
  - user_id: 2
    roles: [admin]
    generate_api_key: true
    enable_score_fetcher: true
initial_roles:
  - admin
setup_steps:
  - create_database
  - seed_roles
  - seed_users
  - seed_api_keys
  - seed_queues
EOF

    # Create .env for direct Python dev mode (only if missing)
    write_config_file "$BACKEND_DIR/.env" <<EOF
DEBUG=true
DISABLE_SECURITY=$DISABLE_SECURITY
ENV=dev
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JWT_SECRET_KEY
JWT_ALGORITHM=HS256
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

    # Create .env.test (only if missing)
    write_config_file "$BACKEND_DIR/.env.test" <<EOF
DEBUG=true
DISABLE_SECURITY=false
ENV=test
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JWT_SECRET_KEY_TEST
JWT_ALGORITHM=HS256
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

    # Create .env for deploy orchestrator (only if missing)
    write_config_file "$SCRIPT_DIR/.env" <<EOF
# BACKEND
DEBUG=true
DISABLE_SECURITY=$DISABLE_SECURITY
ENV=dev
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JWT_SECRET_KEY
JWT_ALGORITHM=HS256
OSU_CLIENT_ID=$OSU_CLIENT_ID
OSU_CLIENT_SECRET=$OSU_CLIENT_SECRET
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
APP_URL=http://localhost:3000
EOF

    echo
    local f
    if [[ ${#CREATED_FILES[@]} -gt 0 ]]; then
        write_success "Created ${#CREATED_FILES[@]} configuration file(s):"
        for f in "${CREATED_FILES[@]}"; do
            echo "  + $f"
        done
    fi
    if [[ ${#SKIPPED_FILES[@]} -gt 0 ]]; then
        write_info "Preserved ${#SKIPPED_FILES[@]} existing file(s) — left untouched:"
        for f in "${SKIPPED_FILES[@]}"; do
            echo "  = $f"
        done
    fi
    echo
    echo "You have been added as admin user $OSU_USER_ID."
    if [[ $EXTRA_QUEUE_COUNT -gt 0 ]]; then
        echo "  $EXTRA_QUEUE_COUNT extra queue(s) configured."
    fi
    if [[ $EXTRA_ADMIN_COUNT -gt 0 ]]; then
        echo "  $EXTRA_ADMIN_COUNT additional admin user(s) configured."
    fi
    echo
}

# Fill any missing config files. No-op (and silent) when everything already exists,
# so this is safe to run on every invocation without clobbering populated configs.
generate_config_files

# =========================
# Help
# =========================

show_help() {
    cat << EOF
Graveboards Deployment Script

Usage: ./deploy.sh [command] [args...]

Commands:
  up [mode] [--follow|-f] [--build] [--no-monitoring] [--nas] [--traefik] [--monitoring-ports] [service...]  - Start services (default: dev)
  down [mode] [--no-monitoring] [--nas] [--traefik] [service...]              - Stop services (default: all)
  build [mode] [--no-monitoring] [--nas] [--traefik] [service...]             - Build images (default: dev)
  pull [repo...]                                          - Git pull repos (all or: backend, frontend, deploy)
  force-pull [repo...]                                    - Force reset repos to origin
  deploy [mode] [--follow|-f] [--no-monitoring] [--nas] [--traefik] [--monitoring-ports] - Full pipeline
  logs [mode] [--no-monitoring] [--nas] [--traefik] [service] - View logs (default: dev all)
  test [--log-file <path>] [--no-cleanup] [--no-log] [--quiet] - Run tests (saves output to log file by default)
  status                                                  - Show status
  clean                                                   - Remove volumes and images
  help                                                    - Show this help

Modes:
  dev       - Development mode (default)
  prod      - Production mode (Docker volumes)
  test      - Testing mode

Flags:
  --build                 - Rebuild images before starting (up)
  --follow, -f            - Run in foreground (up, deploy)
  --no-monitoring         - Skip monitoring stack
  --nas                   - Include NAS volume overrides (prod only)
  --traefik               - Include Traefik overrides for frontend + Grafana (prod only, requires traefik-proxy network)
  --monitoring-ports      - Publish monitoring ports to host (dev only, for local access to Prometheus/Grafana/Loki)
  --monitoring-traefik    - Include Traefik routes for monitoring services (prod only)

Services (for up, down, build, logs):
  all      - All services
  backend  - Backend service
  frontend - Frontend service
  postgres - PostgreSQL database
  redis    - Redis cache

Examples:
  ./deploy.sh up dev                           # Start dev mode (detached + follow logs)
  ./deploy.sh up dev --follow                  # Start dev mode (foreground)
  ./deploy.sh up dev --monitoring-ports        # Start dev with monitoring ports on host
  ./deploy.sh up dev backend                   # Start only backend in dev
  ./deploy.sh up prod                          # Start prod (no NAS, no Traefik, monitoring internal-only)
  ./deploy.sh up prod --nas                    # Start prod with NAS volumes
  ./deploy.sh up prod --traefik                # Start prod with Traefik (Grafana on grafana.graveboards.net)
  ./deploy.sh up prod --nas --traefik          # Start prod with NAS + Traefik
  ./deploy.sh down prod                        # Stop prod mode
  ./deploy.sh build test                       # Build test images
  ./deploy.sh pull                             # Pull all repos
  ./deploy.sh pull backend deploy              # Pull specific repos
  ./deploy.sh force-pull                       # Force update all repos
  ./deploy.sh deploy prod --nas --traefik      # Full prod deployment with NAS + Traefik
  ./deploy.sh deploy prod --follow             # Full deployment with foreground logs
  ./deploy.sh logs dev backend                 # View dev backend logs
  ./deploy.sh test                             # Run tests
  ./deploy.sh status                           # Show status
  ./deploy.sh clean                            # Remove volumes and images

For more information, see README.md
EOF
}

# =========================
# Docker checks
# =========================

if ! command -v docker >/dev/null 2>&1; then
    write_error "Docker is not installed"
    write_info "Please install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    write_error "Docker daemon is not running"
    write_info "Please start Docker"
    exit 1
fi

# =========================
# Command argument parsing
# =========================

Command="${1:-up}"
shift || true

parse_mode_and_flags() {
    local -n _mode=$1
    local -n _follow=$2
    local -n _noMonitoring=$3
    local -n _nas=$4
    local -n _traefik=$5
    local -n _monitoringPorts=$6
    local -n _monitoringTraefik=$7
    local -n _build=$8
    local -n _extra=$9
    shift 9

    _mode="dev"
    _follow="false"
    _noMonitoring="false"
    _nas="false"
    _traefik="false"
    _monitoringPorts="false"
    _monitoringTraefik="false"
    _build="false"
    _extra=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            dev|prod|test)
                if [[ "$_mode" == "dev" ]]; then
                    _mode="$1"
                else
                    _extra+=("$1")
                fi
                shift
                ;;
            --follow|-f)
                _follow="true"
                shift
                ;;
            --no-monitoring)
                _noMonitoring="true"
                shift
                ;;
            --nas)
                _nas="true"
                shift
                ;;
            --traefik)
                _traefik="true"
                shift
                ;;
            --monitoring-ports)
                _monitoringPorts="true"
                shift
                ;;
            --monitoring-traefik)
                _monitoringTraefik="true"
                shift
                ;;
            --build)
                _build="true"
                shift
                ;;
            *)
                _extra+=("$1")
                shift
                ;;
        esac
    done
}

# =========================
# Command implementations
# =========================

cmd_up() {
    local Mode Follow NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik Build
    local -a ExtraServices
    parse_mode_and_flags Mode Follow NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik Build ExtraServices "$@"

    if [[ "$Traefik" == "true" ]]; then
        if ! docker network inspect traefik-proxy &>/dev/null; then
            write_error "Traefik proxy network not found!"
            write_info "Make sure Traefik is running and has created the 'traefik-proxy' network"
            exit 1
        fi
    fi

    local BuildFlag=""
    if [[ "$Build" == "true" ]]; then
        BuildFlag="--build"
    fi

    if [[ "$Follow" == "false" ]]; then
        write_info "Starting Graveboards in $Mode mode..."
        if [[ "$Mode" != "test" ]]; then
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" up $BuildFlag -d "${ExtraServices[@]}"
            write_success "Services started!"
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f "${ExtraServices[@]}"
        else
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" --profile test up --build "${ExtraServices[@]}"
        fi
    else
        write_info "Starting Graveboards in $Mode mode (foreground)..."
        if [[ "$Mode" != "test" ]]; then
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" up $BuildFlag "${ExtraServices[@]}" &
            COMPOSE_PROCESS_PID=$!
            wait $COMPOSE_PROCESS_PID
        else
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" --profile test up --build "${ExtraServices[@]}" &
            COMPOSE_PROCESS_PID=$!
            wait $COMPOSE_PROCESS_PID
        fi
    fi
}

cmd_down() {
    local Mode NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik
    local -a ExtraServices
    parse_mode_and_flags Mode _ NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik _ ExtraServices "$@"

    write_info "Stopping Graveboards services..."

    if [[ ${#ExtraServices[@]} -gt 0 ]]; then
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" down "${ExtraServices[@]}"
    else
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" down
    fi
    write_success "Services stopped!"
}

cmd_build() {
    local Mode NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik
    local -a ExtraServices
    parse_mode_and_flags Mode _ NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik _ ExtraServices "$@"

    write_info "Building Graveboards images for $Mode mode..."

    if [[ ${#ExtraServices[@]} -gt 0 ]]; then
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" build "${ExtraServices[@]}"
    else
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" build
    fi

    cleanup_spec_cache

    write_success "Images built!"
}

cmd_pull() {
    if [[ $# -eq 0 ]]; then
        write_info "Pulling all repositories..."
        git_pull_repo "$BACKEND_DIR" || return 1
        git_pull_repo "$FRONTEND_DIR" || return 1
        git_pull_repo "$SCRIPT_DIR" || return 1
    else
        for repo in "$@"; do
            case "$repo" in
                backend)
                    git_pull_repo "$BACKEND_DIR" || return 1
                    ;;
                frontend)
                    git_pull_repo "$FRONTEND_DIR" || return 1
                    ;;
                deploy)
                    git_pull_repo "$SCRIPT_DIR" || return 1
                    ;;
                *)
                    write_error "Unknown repository: $repo"
                    write_info "Valid repositories: backend, frontend, deploy"
                    return 1
                    ;;
            esac
        done
    fi
    write_success "Repositories updated!"
}

cmd_force_pull() {
    if [[ $# -eq 0 ]]; then
        write_info "Force updating all repositories..."
        git_force_pull_repo "$BACKEND_DIR"
        git_force_pull_repo "$FRONTEND_DIR"
        git_force_pull_repo "$SCRIPT_DIR"
    else
        for repo in "$@"; do
            case "$repo" in
                backend)
                    git_force_pull_repo "$BACKEND_DIR"
                    ;;
                frontend)
                    git_force_pull_repo "$FRONTEND_DIR"
                    ;;
                deploy)
                    git_force_pull_repo "$SCRIPT_DIR"
                    ;;
                *)
                    write_error "Unknown repository: $repo"
                    write_info "Valid repositories: backend, frontend, deploy"
                    exit 1
                    ;;
            esac
        done
    fi
    write_success "Repositories force updated!"
}

cmd_deploy() {
    local Mode Follow NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik Build
    local -a Extra
    parse_mode_and_flags Mode Follow NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik Build Extra "$@"

    if [[ "$Traefik" == "true" ]]; then
        if ! docker network inspect traefik-proxy &>/dev/null; then
            write_error "Traefik proxy network not found!"
            write_info "Make sure Traefik is running and has created the 'traefik-proxy' network"
            exit 1
        fi
    fi

    write_info "Stopping services..."
    compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" down

    write_info "Pulling latest code..."
    if ! cmd_pull; then
        write_error "Deployment aborted because one or more repositories could not be updated."
        exit 1
    fi

    write_info "Building images..."
    compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" build
    cleanup_spec_cache

    write_info "Starting services..."
    if [[ "$Follow" == "true" ]]; then
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" up --build &
        COMPOSE_PROCESS_PID=$!
        wait $COMPOSE_PROCESS_PID
    else
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" up -d
        write_success "Services started!"
        compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f
    fi
}

cmd_logs() {
    local Mode NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik
    local Service="all"
    local -a Extra
    parse_mode_and_flags Mode _ NoMonitoring Nas Traefik MonitoringPorts MonitoringTraefik _ Extra "$@"

    if [[ ${#Extra[@]} -gt 0 ]]; then
        Service="${Extra[0]}"
    fi

    case "$Service" in
        all)
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f
            ;;
        backend)
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f backend
            ;;
        frontend)
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f frontend
            ;;
        postgres|postgresql)
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f postgresql
            ;;
        redis)
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f redis
            ;;
        *)
            write_info "Service '$Service' not found. Showing all logs..."
            compose "$Mode" "$NoMonitoring" "$Nas" "$Traefik" "$MonitoringPorts" "$MonitoringTraefik" logs -f
            ;;
    esac
}

cmd_test() {
    local LogFile=""
    local NoCleanup="false"
    local NoLogFile="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-file)
                LogFile="$2"
                shift 2
                ;;
            --log-file=*)
                LogFile="${1#*=}"
                shift
                ;;
            --no-cleanup)
                NoCleanup="true"
                shift
                ;;
            --no-log)
                NoLogFile="true"
                shift
                ;;
            --quiet)
                shift
                ;;
            *)
                write_error "Unknown test option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    local Timestamp
    Timestamp=$(date +%Y%m%d-%H%M%S)
    if [[ -z "$LogFile" ]] && [[ "$NoLogFile" != "true" ]]; then
        LogFile="$SCRIPT_DIR/test-output-${Timestamp}.log"
    fi

    write_info "Running Graveboards tests in Docker..."
    if [[ -n "$LogFile" ]]; then
        write_info "Log file: $LogFile"
    else
        write_info "Log file: disabled (--no-log)"
    fi

    write_info "Building test image..."
    compose test true false false false false --profile test build --quiet 2>/dev/null || true

    write_info "Starting test services (PostgreSQL, Redis, and backend)..."
    compose test true false false false false --profile test up -d --quiet-pull 2>/dev/null

    write_info "Waiting for test services to be healthy..."
    local health_retries=0
    local max_health_retries=30
    while [[ $health_retries -lt $max_health_retries ]]; do
        if docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" ps postgresql redis 2>/dev/null | grep -q "healthy"; then
            break
        fi
        health_retries=$((health_retries + 1))
        sleep 2
    done

    if [[ $health_retries -eq $max_health_retries ]]; then
        write_error "Test services did not become healthy in time"
        compose test true false false false false logs backend 2>&1
        if [[ "$NoCleanup" != "true" ]]; then
            compose test true false false false false down -v --remove-orphans
        fi
        exit 1
    fi

    local exit_code=0
    set +e
    if [[ -n "$LogFile" ]]; then
        write_info "Running tests (real-time output to terminal and ${LogFile##*/})..."
        set +o pipefail
        compose test true false false false false logs -f backend 2>&1 | tee "$LogFile"
        exit_code=${PIPESTATUS[0]}
        set -o pipefail
    else
        write_info "Running tests (real-time output to terminal)..."
        compose test true false false false false logs -f backend 2>&1
        exit_code=$?
    fi
    set -e

    if [[ $exit_code -ne 0 ]]; then
        write_error "Unexpected non-zero exit code: $exit_code (logs may have been truncated)"
    fi

    local container_exit_code
    container_exit_code=$(docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" ps -q backend 2>/dev/null | xargs -I{} docker inspect --format '{{.State.ExitCode}}' {} 2>/dev/null)
    if [[ -n "$container_exit_code" ]] && [[ "$container_exit_code" -ne 0 ]]; then
        exit_code=$container_exit_code
    fi

    if [[ $exit_code -eq 0 ]]; then
        write_success "Tests passed!"
    else
        write_error "Tests failed! Exit code: $exit_code"
        if [[ -n "$LogFile" ]]; then
            write_error "Full log saved to: $LogFile"
        fi
    fi

    if [[ "$NoCleanup" == "true" ]]; then
        write_warning "Skipping cleanup (--no-cleanup). Containers still running."
    else
        write_info "Test completed, cleaning up..."
        compose test true false false false false down -v --remove-orphans
    fi

    return $exit_code
}

cmd_status() {
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

    printf "\n%s" "Deploy Repository:"
    if [[ -d "$SCRIPT_DIR" ]]; then
        write_success "Found at $SCRIPT_DIR"
    else
        write_error "Not found at $SCRIPT_DIR"
    fi

    printf "\n%s" "Docker:"
    if command -v docker >/dev/null 2>&1; then
        write_success "Docker is installed"
    else
        write_error "Docker is not installed"
    fi

    if docker info >/dev/null 2>&1; then
        write_success "Docker daemon is running"
    else
        write_error "Docker daemon is not running"
    fi

    printf "\n%s\n" "Container Status:"
    docker ps -a --filter "name=graveboards" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_clean() {
    write_warning "This will remove all volumes and images! (excluding prod)"
    read -p "Are you sure? (yes/no): " confirm

    if [[ "$confirm" == "yes" ]]; then
        write_info "Removing volumes and images..."
        "${COMPOSE_CMD[@]}" -f "$SCRIPT_DIR/docker-compose.yml" \
                             -f "$SCRIPT_DIR/docker-compose.monitoring.yml" \
                             down -v --remove-orphans
        "${COMPOSE_CMD[@]}" -f "$SCRIPT_DIR/docker-compose.test.yml" \
                             down -v --remove-orphans
        "${COMPOSE_CMD[@]}" -f "$SCRIPT_DIR/docker-compose.prod.yml" \
                             -f "$SCRIPT_DIR/docker-compose.prod.traefik.yml" \
                             -f "$SCRIPT_DIR/docker-compose.monitoring.yml" \
                             down --remove-orphans

        docker rmi -f $(docker images -q graveboards* 2>/dev/null) 2>/dev/null || true
        write_success "Cleaned up environment"
    else
        write_info "Clean aborted"
    fi
}

# =========================
# Main execution
# =========================

printf "${ColorInfo}Graveboards Deployment Script${ColorReset}\n"
printf "${ColorInfo}=============================${ColorReset}\n\n"

case "$Command" in
    up)
        cmd_up "$@"
        ;;
    down)
        cmd_down "$@"
        ;;
    build)
        cmd_build "$@"
        ;;
    pull)
        cmd_pull "$@" || exit 1
        ;;
    force-pull)
        cmd_force_pull "$@"
        ;;
    deploy)
        cmd_deploy "$@"
        ;;
    logs)
        cmd_logs "$@"
        ;;
    test)
        cmd_test "$@"
        ;;
    status)
        cmd_status
        ;;
    clean)
        cmd_clean
        ;;
    help)
        show_help
        ;;
    *)
        write_error "Unknown command: $Command"
        show_help
        exit 1
        ;;
esac
