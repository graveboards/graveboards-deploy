#!/usr/bin/env pwsh

# Graveboards Deployment Script for Windows
# Usage: .\deploy.ps1 [command] [mode] [service]
#
# Commands:
#   up [mode]               - Start services (default: dev)
#   down [mode]             - Stop services (default: all)
#   build [mode]            - Build images (default: dev)
#   logs [mode] [service]   - View logs (default: dev all)
#   test                    - Run tests
#   status                  - Show status
#   help                    - Show this help

param(
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("up", "down", "build", "logs", "test", "status", "help", "clean")]
    [string]$Command = "up",
    
    [Parameter(Mandatory=$false, Position=1)]
    [ValidateSet("dev", "prod", "prod-nas", "test")]
    [string]$Mode = "dev",
    
    [Parameter(Mandatory=$false, Position=2)]
    [string]$Service = "all",
    
    [Parameter(Mandatory=$false, Position=3)]
    [string]$DisableMonitoring = "false"
)

$SCRIPT_DIR = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$BACKEND_DIR = Join-Path $SCRIPT_DIR "../graveboards-backend"
$FRONTEND_DIR = Join-Path $SCRIPT_DIR "../graveboards-frontend"

# Colors
$ColorInfo = "Cyan"
$ColorSuccess = "Green"
$ColorError = "Red"
$ColorWarning = "Yellow"

function Write-Info { Write-Host "[INFO]" -ForegroundColor $ColorInfo -NoNewline; Write-Host " $args" }
function Write-Success { Write-Host "[OK]" -ForegroundColor $ColorSuccess -NoNewline; Write-Host " $args" }
function Write-Error { Write-Host "[ERROR]" -ForegroundColor $ColorError -NoNewline; Write-Host " $args" }
function Write-Warning { Write-Host "[WARN]" -ForegroundColor $ColorWarning -NoNewline; Write-Host " $args" }

# =========================
# Step 1: Auto-generate .env and bootstrap files if they don't exist
# =========================

function Generate-ConfigFiles {
    Write-Info "Configuration files not found. Starting interactive setup..."
    Write-Host ""

    # Generate 32-character random alphanumeric secrets
    $Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $JwtSecretKey = -join ((1..32) | ForEach-Object { $Chars[(Get-Random -Minimum 0 -Maximum $Chars.Length)] })
    $JwtSecretKeyTest = -join ((1..32) | ForEach-Object { $Chars[(Get-Random -Minimum 0 -Maximum $Chars.Length)] })
    $SessionSecret = -join ((1..32) | ForEach-Object { $Chars[(Get-Random -Minimum 0 -Maximum $Chars.Length)] })

    Write-Host "You can set up your osu client credentials here:"
    Write-Host "https://osu.ppy.sh/home/account/edit#oauth"
    Write-Host "Step 1: Click 'New OAuth Application +'"
    Write-Host "Step 2: Use http://localhost:3000/callback as callback URL"
    Write-Host ""

    $OSU_CLIENT_ID = Read-Host "Please paste your OSU_CLIENT_ID"
    $OSU_CLIENT_SECRET = Read-Host "Please paste your OSU_CLIENT_SECRET"
    $OSU_USER_ID = Read-Host "Enter your osu user ID to add yourself as an admin"
    Write-Host ""

    $choice = Read-Host "Disable security for dev convenience? (y/N)"
    if ($choice -eq 'y' -or $choice -eq 'Y') {
        $DISABLE_SECURITY = "true"
    } else {
        $DISABLE_SECURITY = "false"
    }

    # Master queue configuration
    $MasterQueueName = Read-Host "Master queue name [Graveboards Queue]"
    if (-not $MasterQueueName) { $MasterQueueName = "Graveboards Queue" }

    $MasterQueueDescription = Read-Host "Master queue description [Master queue for beatmaps to receive leaderboards]"
    if (-not $MasterQueueDescription) { $MasterQueueDescription = "Master queue for beatmaps to receive leaderboards" }

    # Extra queues
    $ExtraQueues = [System.Collections.Generic.List[object]]::new()
    $addQueues = Read-Host "Add extra queues? (y/N)"
    if ($addQueues -eq 'y' -or $addQueues -eq 'Y') {
        do {
            $qName = Read-Host "  Queue name"
            $qDesc = Read-Host "  Queue description"
            $qUid = Read-Host "  Owner user ID"
            $ExtraQueues.Add([PSCustomObject]@{ Name = $qName; Description = $qDesc; UserId = $qUid }) | Out-Null
            $again = Read-Host "  Add another queue? (y/N)"
        } while ($again -eq 'y' -or $again -eq 'Y')
    }

    # Additional admin users
    $ExtraAdmins = [System.Collections.Generic.List[string]]::new()
    $addAdmins = Read-Host "Add additional admin users? (y/N)"
    if ($addAdmins -eq 'y' -or $addAdmins -eq 'Y') {
        do {
            $extraAdminId = Read-Host "  osu user ID"
            $ExtraAdmins.Add($extraAdminId) | Out-Null
            $again = Read-Host "  Add another admin? (y/N)"
        } while ($again -eq 'y' -or $again -eq 'Y')
    }

    # --- Generate bootstrap.yaml for dev ---
    $configDir = Join-Path $BACKEND_DIR "config"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir | Out-Null
    }

    $yamlLines = @()
    $yamlLines += "master_queue:"
    $yamlLines += "  name: `"$MasterQueueName`""
    $yamlLines += "  description: `"$MasterQueueDescription`""
    $yamlLines += "  user_id: $OSU_USER_ID"

    if ($ExtraQueues.Count -gt 0) {
        $yamlLines += "extra_queues:"
        foreach ($q in $ExtraQueues) {
            $yamlLines += "  - user_id: $($q.UserId)"
            $yamlLines += "    name: `"$($q.Name)`""
            $yamlLines += "    description: `"$($q.Description)`""
        }
    } else {
        $yamlLines += "extra_queues: []"
    }

    $yamlLines += "initial_users:"
    $yamlLines += "  - user_id: $OSU_USER_ID"
    $yamlLines += "    roles: [admin]"
    $yamlLines += "    generate_api_key: true"
    $yamlLines += "    enable_score_fetcher: true"

    foreach ($adminId in $ExtraAdmins) {
        $yamlLines += "  - user_id: $adminId"
        $yamlLines += "    roles: [admin]"
        $yamlLines += "    generate_api_key: true"
        $yamlLines += "    enable_score_fetcher: true"
    }

    $yamlLines += "initial_roles:"
    $yamlLines += "  - admin"
    $yamlLines += "setup_steps:"
    $yamlLines += "  - create_database"
    $yamlLines += "  - seed_roles"
    $yamlLines += "  - seed_users"
    $yamlLines += "  - seed_api_keys"
    $yamlLines += "  - seed_queues"

    $yamlContent = $yamlLines -join "`n"
    Set-Content -Path (Join-Path $configDir "bootstrap.yaml") -Value $yamlContent

    # --- Generate bootstrap.test.yaml ---
    $testYaml = @"
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
"@
    Set-Content -Path (Join-Path $configDir "bootstrap.test.yaml") -Value $testYaml

    # Create .env for direct Python dev mode (connects to Docker DB/Redis via localhost)
    $envDevContent = @"
DEBUG=true
DISABLE_SECURITY=$DISABLE_SECURITY
ENV=dev
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JwtSecretKey
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
"@

    Set-Content -Path (Join-Path $BACKEND_DIR ".env") -Value $envDevContent

    # Create .env.test for test mode (isolated DB/Redis)
    $envTestContent = @"
DEBUG=true
DISABLE_SECURITY=false
ENV=test
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JwtSecretKeyTest
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
"@

    Set-Content -Path (Join-Path $BACKEND_DIR ".env.test") -Value $envTestContent

    # Create .env for deploy orchestrator
    $envDeployContent = @"
# BACKEND
DEBUG=true
DISABLE_SECURITY=$DISABLE_SECURITY
ENV=dev
BASE_URL=http://localhost:3000
JWT_SECRET_KEY=$JwtSecretKey
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
SESSION_SECRET=$SessionSecret
APP_URL=http://localhost:3000
"@

    Set-Content -Path (Join-Path $SCRIPT_DIR ".env") -Value $envDeployContent

    Write-Host ""
    Write-Success "[OK] Configuration files created:"
    Write-Host "  - $(Join-Path $BACKEND_DIR '.env') (dev mode with localhost DB/Redis)"
    Write-Host "  - $(Join-Path $BACKEND_DIR '.env.test') (test mode with isolated DB/Redis)"
    Write-Host "  - $(Join-Path $configDir 'bootstrap.yaml') (dev bootstrap config)"
    Write-Host "  - $(Join-Path $configDir 'bootstrap.test.yaml') (test bootstrap config)"
    Write-Host "  - $(Join-Path $SCRIPT_DIR '.env') (deploy orchestrator config)"
    Write-Host ""
    Write-Host "You have been added as admin user $OSU_USER_ID."
    if ($ExtraQueues.Count -gt 0) {
        Write-Host "  $($_.Count) extra queue(s) configured."
    }
    if ($ExtraAdmins.Count -gt 0) {
        Write-Host "  $($ExtraAdmins.Count) additional admin user(s) configured."
    }
    Write-Host ""
}

# Check if .env files exist, generate if not
if (-not (Test-Path (Join-Path $BACKEND_DIR ".env"))) {
    Generate-ConfigFiles
}

# =========================
# Step 2: Check Docker in PATH
# =========================

function Test-DockerInstalled {
    try {
        docker --version | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-DockerRunning {
    try {
        docker info | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Show-Help {
    Write-Host @"
Graveboards Deployment Script for Windows
Usage: .\deploy.ps1 [command] [mode] [service] [disable-monitoring]

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

Flags:
  disable-monitoring - Disable monitoring stack (Prometheus, Grafana, Alertmanager, Loki, Promtail)

Services:
  all       - All services
  backend   - Backend service
  frontend  - Frontend service
  postgres  - PostgreSQL database
  redis     - Redis cache

Examples:
  .\deploy.ps1 up dev                     # Start dev mode
  .\deploy.ps1 up prod                    # Start prod mode (monitoring enabled by default)
  .\deploy.ps1 up prod disable-monitoring # Start prod mode without monitoring
  .\deploy.ps1 down prod                  # Stop prod mode
  .\deploy.ps1 build test                 # Build test images
  .\deploy.ps1 logs dev                   # View dev logs (all services)
  .\deploy.ps1 logs dev backend           # View dev backend logs only
  .\deploy.ps1 logs prod all              # View prod all logs
  .\deploy.ps1 logs test backend          # View test backend logs only

For more information, see README.md
"@
}

function Start-Services {
    param(
        [string]$Mode,
        [string]$DisableMonitoring = "false"
    )
    
    Write-Info "Starting Graveboards in $Mode mode..."
    
    try {
        switch ($Mode) {
            "dev" {
                $composeFiles = @("-f", "$SCRIPT_DIR\docker-compose.yml")
                if ($DisableMonitoring -ne "true") {
                    $composeFiles += "-f", "$SCRIPT_DIR\docker-compose.monitoring.yml"
                    Write-Info "Monitoring stack enabled (Prometheus, Grafana, Alertmanager, Loki, Promtail)"
                } else {
                    Write-Info "Monitoring stack disabled"
                }
                docker-compose $composeFiles up --build
            }
            "prod" {
                if (-not (Test-Path "$SCRIPT_DIR\.env") -and -not (Test-Path "$SCRIPT_DIR\.env.prod")) {
                    Write-Error "Production mode requires .env or .env.prod file with credentials"
                    Write-Warning "Copy .env.prod.example to .env.prod and fill in your values:"
                    Write-Host "  copy .env.prod.example .env.prod"
                    Write-Host "  notepad .env.prod"
                    exit 1
                }
                $composeFiles = @("-f", "$SCRIPT_DIR\docker-compose.prod.yml")
                if ($DisableMonitoring -ne "true") {
                    $composeFiles += "-f", "$SCRIPT_DIR\docker-compose.monitoring.yml"
                }
                docker-compose $composeFiles up --build
            }
            "prod-nas" {
                if (-not (Test-Path "$SCRIPT_DIR\.env") -and -not (Test-Path "$SCRIPT_DIR\.env.prod")) {
                    Write-Error "Production mode requires .env or .env.prod file with credentials"
                    Write-Warning "Copy .env.prod.example to .env.prod and fill in your values:"
                    Write-Host "  copy .env.prod.example .env.prod"
                    Write-Host "  notepad .env.prod"
                    exit 1
                }
                $nasComposeFiles = @("-f", "$SCRIPT_DIR\docker-compose.prod.yml", "-f", "$SCRIPT_DIR\docker-compose.prod-nas.yml")
                if ($DisableMonitoring -ne "true") {
                    $nasComposeFiles += "-f", "$SCRIPT_DIR\docker-compose.monitoring.yml"
                }
                docker-compose $nasComposeFiles up --build
            }
            "test" {
                docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" up --profile test --build
            }
        }
    }
    finally {
        $lastExitCode = $LASTEXITCODE
        if ($lastExitCode -ne 0 -or -not (Test-Path "Function:\Global:Write-Error")) {
            Write-Info "Stopping services..."
            docker-compose -f "$SCRIPT_DIR\docker-compose.yml" down *> $null
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" down *> $null
            docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" --profile test down *> $null
        }
    }
}

function Stop-Services {
    param(
        [string]$Mode
    )
    
    Write-Info "Stopping Graveboards services..."
    
    switch ($Mode) {
        "all" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.yml" down
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" down
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" -f "$SCRIPT_DIR\docker-compose.prod-nas.yml" down
            docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" --profile test down
        }
        "dev" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.yml" down
        }
        "prod" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" down
        }
        "prod-nas" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" -f "$SCRIPT_DIR\docker-compose.prod-nas.yml" down
        }
        "test" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" --profile test down
        }
    }
}

function Build-Images {
    param(
        [string]$Mode
    )
    
    Write-Info "Building Graveboards images for $Mode mode..."
    
    switch ($Mode) {
        "dev" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.yml" build
        }
        "prod" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" build
        }
        "prod-nas" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" build
        }
        "test" {
            docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" --profile test build
        }
    }
}

function View-Logs {
    param(
        [string]$Mode,
        [string]$Service = "all"
    )
    
    switch ($Mode) {
        "dev" {
            $ComposeFile = "$SCRIPT_DIR\docker-compose.yml"
        }
        "prod" {
            $ComposeFile = "$SCRIPT_DIR\docker-compose.prod.yml"
        }
        "prod-nas" {
            $ComposeFile = "$SCRIPT_DIR\docker-compose.prod.yml"
        }
        "test" {
            $ComposeFile = "$SCRIPT_DIR\docker-compose.test.yml"
        }
        default {
            Write-Info "Using default dev mode..."
            $ComposeFile = "$SCRIPT_DIR\docker-compose.yml"
            $Mode = "dev"
        }
    }
    
    switch ($Service) {
        "all" {
            docker-compose -f "$ComposeFile" logs -f
        }
        "backend" {
            docker-compose -f "$ComposeFile" logs -f backend
        }
        "frontend" {
            docker-compose -f "$ComposeFile" logs -f frontend
        }
        "postgres" {
            docker-compose -f "$ComposeFile" logs -f postgresql
        }
        "postgresql" {
            docker-compose -f "$ComposeFile" logs -f postgresql
        }
        "redis" {
            docker-compose -f "$ComposeFile" logs -f redis
        }
        default {
            Write-Info "Service '$Service' not found. Showing all logs..."
            docker-compose -f "$ComposeFile" logs -f
        }
    }
}

function Run-Tests {
    Write-Info "Running Graveboards tests in Docker..."
    
    Write-Info "Building and running test services (PostgreSQL, Redis, and backend)..."
    docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" --profile test up --build -d
    
    Write-Info "Waiting for backend test container to complete..."
    docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" logs -f backend
    
    Write-Info "Test completed, cleaning up..."
    docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" down -v --remove-orphans
}

function Show-Status {
    Write-Info "Graveboards Service Status"
    Write-Host "=========================="
    
    Write-Host "`nBackend Repository:" -ForegroundColor $ColorInfo
    if (Test-Path $BACKEND_DIR) {
        Write-Success "Found at $BACKEND_DIR"
    } else {
        Write-Error "Not found at $BACKEND_DIR"
    }
    
    Write-Host "`nFrontend Repository:" -ForegroundColor $ColorInfo
    if (Test-Path $FRONTEND_DIR) {
        Write-Success "Found at $FRONTEND_DIR"
    } else {
        Write-Error "Not found at $FRONTEND_DIR"
    }
    
    Write-Host "`nDocker:" -ForegroundColor $ColorInfo
    if (Test-DockerInstalled) {
        Write-Success "Docker is installed"
    } else {
        Write-Error "Docker is not installed"
    }
    
    if (Test-DockerRunning) {
        Write-Success "Docker daemon is running"
    } else {
        Write-Error "Docker daemon is not running"
    }
    
    Write-Host "`nContainer Status:" -ForegroundColor $ColorInfo
    docker ps -a --filter "name=graveboards" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

function Clean-Environment {
    Write-Warning "This will remove all volumes and images! (excluding prod)"
    $confirm = Read-Host "Are you sure? (yes/no)"
    
    if ($confirm -eq "yes") {
        Write-Info "Removing volumes and images..."
        docker-compose -f "$SCRIPT_DIR\docker-compose.yml" down -v
        docker-compose -f "$SCRIPT_DIR\docker-compose.test.yml" --profile test down -v
        docker-compose -f "$SCRIPT_DIR\docker-compose.prod.yml" down

        docker rmi -f $(docker images -q graveboards* 2>$null) 2>$null
        Write-Success "Cleaned up environment"
    } else {
        Write-Info "Clean aborted"
    }
}

# Main execution
Write-Host "Graveboards Deployment Script for Windows" -ForegroundColor $ColorInfo
Write-Host "=========================================" -ForegroundColor $ColorInfo
Write-Host ""

# Check Docker
if (-not (Test-DockerInstalled)) {
    Write-Error "Docker is not installed"
    Write-Info "Please install Docker Desktop: https://www.docker.com/products/docker-desktop"
    exit 1
}

if (-not (Test-DockerRunning)) {
    Write-Error "Docker daemon is not running"
    Write-Info "Please start Docker Desktop"
    exit 1
}

switch ($Command) {
    "help" { Show-Help }
    "up" { Start-Services -Mode $Mode -DisableMonitoring $DisableMonitoring }
    "down" { Stop-Services -Mode $Mode }
    "build" { Build-Images -Mode $Mode }
    "logs" { View-Logs -Mode $Mode -Service $Service }
    "test" { Run-Tests }
    "status" { Show-Status }
    "clean" { Clean-Environment }
    default { 
        Write-Error "Unknown command: $Command"
        Show-Help
        exit 1
    }
}

exit 0
