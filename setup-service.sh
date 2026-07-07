#!/usr/bin/env bash

# Graveboards Systemd Service Generator
# Interactive setup to generate and optionally install a systemd service unit.

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

ask() {
    local prompt="$1"
    local default="$2"
    local response

    if [[ -n "$default" ]]; then
        read -rp "${prompt} [$default]: " response
        response="${response:-$default}"
    else
        read -rp "${prompt}: " response
    fi
    echo "$response"
}

ask_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local prompt_suffix
    local response

    if [[ "$default" =~ ^[Yy]$ ]]; then
        prompt_suffix="[Y/n]"
    else
        prompt_suffix="[y/N]"
    fi

    read -rp "${prompt} ${prompt_suffix}: " response

    if [[ -z "$response" ]]; then
        [[ "$default" =~ ^[Yy]$ ]]
    else
        [[ "$response" =~ ^[Yy]$ ]]
    fi
}

# ============================================================
# Step 1: Collect configuration
# ============================================================

echo
write_info "Graveboards Systemd Service Generator"
printf "${ColorInfo}======================================${ColorReset}\n\n"

# --- Deploy directory ---
DEPLOY_DIR=$(ask "Deploy directory (path to graveboards-deploy)" "$SCRIPT_DIR")
DEPLOY_DIR="${DEPLOY_DIR%/}"

if [[ ! -d "$DEPLOY_DIR" ]]; then
    write_error "Directory not found: $DEPLOY_DIR"
    exit 1
fi

# --- Compose file selection ---
echo
write_info "Select the production compose configuration (base prod is always included):"
echo "  1) prod-nas          (NAS volumes override)"
echo "  2) prod-traefik      (Traefik reverse proxy)"
echo

COMPOSE_NAS=false
COMPOSE_TRAEFIK=false

if ask_confirm "  Enable prod-nas?" "y"; then
    COMPOSE_NAS=true
fi

if ask_confirm "  Enable prod-traefik?" "y"; then
    COMPOSE_TRAEFIK=true
fi

COMPOSE_FILES=("$DEPLOY_DIR/docker-compose.prod.yml")
COMPOSE_DESC="prod"

if [[ "$COMPOSE_NAS" == "true" ]]; then
    COMPOSE_FILES+=("$DEPLOY_DIR/docker-compose.prod-nas.yml")
    COMPOSE_DESC+="+nas"
fi

if [[ "$COMPOSE_TRAEFIK" == "true" ]]; then
    COMPOSE_FILES+=("$DEPLOY_DIR/docker-compose.prod-traefik.yml")
    COMPOSE_DESC+="+traefik"
fi

write_success "Compose configuration: $COMPOSE_DESC"

# --- Validate env file for NAS volumes ---
if [[ "$COMPOSE_NAS" == "true" ]]; then
    ENV_FILE="$DEPLOY_DIR/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        write_error "prod-nas requires $ENV_FILE"
        write_info "Create .env with POSTGRESQL_DATA_PATH, REDIS_DATA_PATH, INSTANCE_DATA_PATH set"
        exit 1
    fi

    # Check if volume paths are set (not empty)
    source "$ENV_FILE" 2>/dev/null || true
    if [[ -z "${POSTGRESQL_DATA_PATH}" ]] || [[ -z "${REDIS_DATA_PATH}" ]] || [[ -z "${INSTANCE_DATA_PATH}" ]]; then
        write_error "Volume paths not set in $ENV_FILE"
        write_info "Set POSTGRESQL_DATA_PATH, REDIS_DATA_PATH, and INSTANCE_DATA_PATH"
        exit 1
    fi
fi

# --- Service type ---
echo
write_info "Service type:"
echo "  1) oneshot  (start once, RemainAfterExit=yes — recommended)"
echo "  2) simple   (foreground process, restarts on crash)"
echo

SERVICE_TYPE_CHOICE=$(ask "Choice" "1")

case "$SERVICE_TYPE_CHOICE" in
    1) SERVICE_TYPE="oneshot"; REMAIN_AFTER_EXIT="yes" ;;
    2) SERVICE_TYPE="simple"; REMAIN_AFTER_EXIT="" ;;
    *)
        write_error "Invalid choice: $SERVICE_TYPE_CHOICE"
        exit 1
        ;;
esac

# --- Environment variables ---
# Docker-compose reads from .env file in the deploy directory, no need to set them in systemd

# --- Dedicated user ---
echo
DEDICATED_USER=""
if ask_confirm "Run the service under a dedicated system user?" "n"; then
    DEDICATED_USER=$(ask "Username (e.g. graveboards)")
    if [[ -z "$DEDICATED_USER" ]]; then
        write_warning "No dedicated user specified, running as root"
    fi
fi

# --- System vs user systemd ---
echo
write_info "Installation target:"
echo "  1) system  (all users, requires sudo)"
echo "  2) user    (current user only, no sudo needed)"
echo

INSTALL_CHOICE=$(ask "Choice" "1")

case "$INSTALL_CHOICE" in
    1)
        INSTALL_SCOPE="system"
        SERVICE_DIR="/etc/systemd/system"
        SUDO_REQUIRED=true
        ;;
    2)
        INSTALL_SCOPE="user"
        SERVICE_DIR="$(systemctl --user --no-pager show -p User 2>/dev/null | cut -d= -f2)"
        if [[ -z "$SERVICE_DIR" ]]; then
            SERVICE_DIR="$HOME/.config/systemd/user"
        fi
        SUDO_REQUIRED=false
        ;;
    *)
        write_error "Invalid choice: $INSTALL_CHOICE"
        exit 1
        ;;
esac

# --- Enable on boot ---
ENABLE_ON_BOOT=true
if ! ask_confirm "Enable service to start on boot?" "y"; then
    ENABLE_ON_BOOT=false
fi

# ============================================================
# Step 2: Generate the .service file
# ============================================================

SERVICE_NAME="graveboards"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}.service"

# Prefer 'docker compose' (v2 plugin), fall back to 'docker-compose' (v1)
if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN="docker compose"
else
    COMPOSE_BIN="docker-compose"
fi

build_compose_cmd() {
    local cmd="$COMPOSE_BIN"
    for f in "${COMPOSE_FILES[@]}"; do
        cmd+=" -f $f"
    done
    cmd+=" $1"
    echo "$cmd"
}

COMPOSE_CMD=$(build_compose_cmd "up -d")
COMPOSE_DOWN_CMD=$(build_compose_cmd "down")
COMPOSE_RESTART_CMD=$(build_compose_cmd "restart")

# Build the service file content
if [[ "$INSTALL_SCOPE" == "system" ]]; then
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Graveboards Backend Service
Requires=docker.service network-online.target
After=docker.service network-online.target
Wants=network-online.target
EOF
else
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Graveboards Backend Service
After=basic.target
Wants=basic.target
EOF
fi

cat >> "${SERVICE_FILE}" <<EOF

[Service]
Type=${SERVICE_TYPE}
RemainAfterExit=${REMAIN_AFTER_EXIT}

# Environment
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# User and group
EOF

if [[ -n "$DEDICATED_USER" ]]; then
    cat >> "${SERVICE_FILE}" <<EOF
User=${DEDICATED_USER}
Group=${DEDICATED_USER}
EOF
fi

cat >> "${SERVICE_FILE}" <<EOF

# Security options
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only

# Working directory
WorkingDirectory=${DEPLOY_DIR}

# Start command
ExecStart=${COMPOSE_CMD}

# Stop command
ExecStop=${COMPOSE_DOWN_CMD}

# Restart command
ExecReload=${COMPOSE_RESTART_CMD}

# Restart policy
EOF

if [[ "$SERVICE_TYPE" == "oneshot" ]]; then
    cat >> "${SERVICE_FILE}" <<EOF
Restart=on-failure
RestartSec=30
EOF
else
    cat >> "${SERVICE_FILE}" <<EOF
Restart=always
RestartSec=30
EOF
fi

# Logging
cat >> "${SERVICE_FILE}" <<EOF
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=$(if [[ "$INSTALL_SCOPE" == "system" ]]; then echo "multi-user.target"; else echo "default.target"; fi)
EOF

write_success "Service file generated: ${SERVICE_FILE}"

# ============================================================
# Step 3: Install and enable the service
# ============================================================

echo
write_info "Installing systemd service..."

if [[ "$SUDO_REQUIRED" == "true" ]]; then
    if sudo -n true 2>/dev/null; then
        sudo systemctl daemon-reload
        if [[ "$ENABLE_ON_BOOT" == "true" ]]; then
            sudo systemctl enable "${SERVICE_NAME}.service"
        fi
        sudo systemctl start "${SERVICE_NAME}.service"
        if [[ "$ENABLE_ON_BOOT" == "true" ]]; then
            write_success "Service installed, enabled, and started (system-wide)"
        else
            write_success "Service installed and started (system-wide)"
        fi
    else
        write_warning "sudo requires a password. Running commands now..."
        sudo systemctl daemon-reload
        if [[ "$ENABLE_ON_BOOT" == "true" ]]; then
            sudo systemctl enable "${SERVICE_NAME}.service"
        fi
        sudo systemctl start "${SERVICE_NAME}.service"
        if [[ "$ENABLE_ON_BOOT" == "true" ]]; then
            write_success "Service installed, enabled, and started (system-wide)"
        else
            write_success "Service installed and started (system-wide)"
        fi
    fi
else
    systemctl --user daemon-reload
    if [[ "$ENABLE_ON_BOOT" == "true" ]]; then
        systemctl --user enable "${SERVICE_NAME}.service"
    fi
    systemctl --user start "${SERVICE_NAME}.service"
    if [[ "$ENABLE_ON_BOOT" == "true" ]]; then
        write_success "Service installed, enabled, and started (user-level)"
    else
        write_success "Service installed and started (user-level)"
    fi
fi

# ============================================================
# Step 4: Show management commands
# ============================================================

echo
write_info "Management commands:"
echo
if [[ "$SUDO_REQUIRED" == "true" ]]; then
    echo "  Start:   sudo systemctl start ${SERVICE_NAME}"
    echo "  Stop:    sudo systemctl stop ${SERVICE_NAME}"
    echo "  Restart: sudo systemctl restart ${SERVICE_NAME}"
    echo "  Status:  sudo systemctl status ${SERVICE_NAME}"
    echo "  Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
else
    echo "  Start:   systemctl --user start ${SERVICE_NAME}"
    echo "  Stop:    systemctl --user stop ${SERVICE_NAME}"
    echo "  Restart: systemctl --user restart ${SERVICE_NAME}"
    echo "  Status:  systemctl --user status ${SERVICE_NAME}"
    echo "  Logs:    journalctl --user -u ${SERVICE_NAME} -f"
fi

echo
write_success "Done!"
