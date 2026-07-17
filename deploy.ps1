#!/usr/bin/env pwsh

# Graveboards Deployment Script for Windows
# Usage: .\deploy.ps1 [command] [args...]
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

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Command = "up",

    [Parameter(Mandatory=$false, Position=1, ValueFromRemainingArguments=$true)]
    [string[]]$Args = @()
)

$SCRIPT_DIR = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$BACKEND_DIR = Join-Path $SCRIPT_DIR "..\graveboards-backend"
$FRONTEND_DIR = Join-Path $SCRIPT_DIR "..\graveboards-frontend"

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
# Grafana deploy annotation
# =========================

function Invoke-GrafanaAnnotation {
    param(
        [string]$Text,
        [string]$Tags
    )

    $grafanaUrl = if ($env:GRAFANA_URL) { $env:GRAFANA_URL } else { "http://localhost:3001" }
    $grafanaToken = $env:GRAFANA_DEPLOY_ANNOTATION_TOKEN

    if (-not $grafanaToken) {
        Write-Info "GRAFANA_DEPLOY_ANNOTATION_TOKEN not set - skipping Grafana annotation."
        return
    }

    Write-Info "Pushing deploy annotation to Grafana: $Text"
    $timestamp = [int]((Get-Date -UFormat %s) * 1000)
    $body = @{
        text = $Text
        tags = @($Tags -split ',')
        time = $timestamp
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod -Uri "${grafanaUrl}/api/annotations" -Method Post -Headers @{
            Authorization = "Bearer ${grafanaToken}"
            "Content-Type" = "application/json"
        } -Body $body -ErrorAction Stop | Out-Null
        Write-Success "Grafana annotation pushed."
    } catch {
        Write-Warning "Failed to push Grafana annotation (non-fatal): $_"
    }
}

# =========================
# Docker Compose command detection
# =========================

$COMPOSE_CMD = $null
try {
    docker compose version | Out-Null
    $COMPOSE_CMD = @("docker", "compose")
} catch {
    try {
        docker-compose --version | Out-Null
        $COMPOSE_CMD = @("docker-compose")
    } catch {
        Write-Error "Docker Compose is not installed"
        Write-Info "Install Docker Compose v2: https://docs.docker.com/compose/install/"
        exit 1
    }
}

# =========================
# Compose wrapper function
# =========================

function Build-ComposeArgs {
    param(
        [string]$Mode,
        [string]$NoMonitoring = "false",
        [string]$Nas = "false",
        [string]$Traefik = "false",
        [string]$MonitoringTraefik = "false",
        [string]$NoFrontend = "false"
    )

    $composeFiles = @()

    switch ($Mode) {
        "dev" {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.yml"
        }
        "prod" {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.prod.yml"
            if ($Nas -eq "true") {
                $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.prod.nas.yml"
            }
            if ($Traefik -eq "true") {
                $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.prod.traefik.yml"
            }
        }
        "test" {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.test.yml"
        }
        default {
            Write-Error "Unknown mode: $Mode"
            exit 1
        }
    }

    if ($Mode -ne "test" -and $NoMonitoring -ne "true") {
        $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.yml"
        if ($Mode -eq "dev") {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.ports.yml"
        }
        if ($MonitoringTraefik -eq "true") {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.traefik.yml"
        }
    }

    if ($Mode -eq "prod" -and $NoMonitoring -ne "true") {
        $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.prod.yml"
    }

    if ($NoFrontend -ne "true") {
        $composeFiles += "--profile", "frontend"
    }

    return $composeFiles
}

function Invoke-Compose {
    param(
        [string]$Mode,
        [string]$NoMonitoring = "false",
        [string]$Nas = "false",
        [string]$Traefik = "false",
        [string]$MonitoringTraefik = "false",
        [string]$NoFrontend = "false",
        [string[]]$ExtraArgs = @()
    )

    $composeFiles = Build-ComposeArgs -Mode $Mode -NoMonitoring $NoMonitoring -Nas $Nas -Traefik $Traefik -MonitoringTraefik $MonitoringTraefik -NoFrontend $NoFrontend

    # Picked up by docker-compose.yml/docker-compose.prod.yml as the backend
    # build arg GIT_COMMIT, since the image itself has no .git to introspect.
    # Re-resolved on every call so it reflects the checkout after Git-PullRepo.
    Push-Location $BACKEND_DIR
    try {
        $commit = git rev-parse --short HEAD 2>$null
        $env:GIT_COMMIT = if ($LASTEXITCODE -eq 0 -and $commit) { $commit } else { "unknown" }
    } finally {
        Pop-Location
    }

    $fullArgs = $composeFiles + $ExtraArgs

    if ($COMPOSE_CMD.Count -gt 1) {
        # docker compose (v2 plugin): COMPOSE_CMD = @("docker", "compose")
        & docker compose @fullArgs
    } else {
        # docker-compose (standalone): COMPOSE_CMD = @("docker-compose")
        & docker-compose @fullArgs
    }
    $global:LASTEXITCODE = $LASTEXITCODE
}

# =========================
# Git helper functions
# =========================

function Git-PullRepo {
    param([string]$Repo)

    Write-Info "Pulling $(Split-Path $Repo -Leaf)..."
    Push-Location $Repo
    try {
        # Pipe git's stdout to the host so it does not pollute this function's
        # return value; a native non-zero exit does not throw, so check exit code.
        git pull --ff-only | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to pull $(Split-Path $Repo -Leaf)."
            return $false
        }
        Write-Success "Updated $(Split-Path $Repo -Leaf)"
        return $true
    } finally {
        Pop-Location
    }
}

function Git-ForcePullRepo {
    param([string]$Repo)

    Write-Info "Force updating $(Split-Path $Repo -Leaf)..."
    Push-Location $Repo
    try {
        $branch = git rev-parse --abbrev-ref HEAD
        git fetch origin
        git reset --hard "origin/$branch"
        git clean -fd
        Write-Success "Force updated $(Split-Path $Repo -Leaf)"
    } finally {
        Pop-Location
    }
}

# =========================
# Spec cache cleanup
# =========================

function Get-SpecCachePath {
    $envFile = Join-Path $SCRIPT_DIR ".env"
    if (Test-Path $envFile) {
        $instanceDataPath = Get-Content $envFile | Where-Object { $_ -match '^INSTANCE_DATA_PATH=' } | ForEach-Object { (($_ -split '=', 2)[1]).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($instanceDataPath)) {
            return Join-Path $instanceDataPath ".spec_cache.pkl"
        }
    }
    return $null
}

function Cleanup-SpecCache {
    $specCache = Get-SpecCachePath
    if (-not [string]::IsNullOrWhiteSpace($specCache) -and (Test-Path $specCache)) {
        Write-Info "Deleting spec cache: $specCache"
        Remove-Item $specCache -Force -ErrorAction SilentlyContinue
    }
}

# =========================
# Cleanup on exit / Ctrl+C
# =========================

$script:COMPOSE_PROCESS_PID = $null

function Cleanup-Services {
    Write-Info "Stopping services..."
    $composeFiles = @("-f", "$SCRIPT_DIR/docker-compose.yml",
                      "-f", "$SCRIPT_DIR/docker-compose.prod.yml",
                      "-f", "$SCRIPT_DIR/docker-compose.test.yml",
                      "-f", "$SCRIPT_DIR/docker-compose.monitoring.yml",
                      "down", "--remove-orphans")
    if ($COMPOSE_CMD.Count -gt 1) {
        & docker compose @composeFiles 2>$null
    } else {
        & docker-compose @composeFiles 2>$null
    }
}



# =========================
# Interactive config generation
# =========================

# Config files this script manages. A file is only ever (re)generated when it is
# missing or empty - an existing, non-empty file is ALWAYS preserved, so running
# against a populated repo (e.g. a configured production .env) never destroys it.
function Get-ConfigTargets {
    return @(
        (Join-Path $BACKEND_DIR "config\bootstrap.yaml"),
        (Join-Path $BACKEND_DIR "config\bootstrap.test.yaml"),
        (Join-Path $BACKEND_DIR ".env"),
        (Join-Path $BACKEND_DIR ".env.test"),
        (Join-Path $SCRIPT_DIR ".env")
    )
}

# A target is "missing" (safe to write) when absent or zero-length.
function Test-NeedsContent {
    param([string]$Path)
    return (-not (Test-Path -LiteralPath $Path)) -or ((Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Length -eq 0)
}

$script:CreatedFiles = @()
$script:SkippedFiles = @()

# Write $Content to $Path only if it is missing/empty; otherwise preserve the
# existing file. Outcome is recorded for the summary.
function Write-ConfigFile {
    param([string]$Path, [string]$Content)
    if (Test-NeedsContent -Path $Path) {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -Path $Path -Value $Content
        $script:CreatedFiles += $Path
    } else {
        $script:SkippedFiles += $Path
    }
}

function Generate-ConfigFiles {
    # Prompt only when at least one managed file is missing; otherwise no-op.
    $missing = @(Get-ConfigTargets | Where-Object { Test-NeedsContent -Path $_ })
    if ($missing.Count -eq 0) { return }

    $script:CreatedFiles = @()
    $script:SkippedFiles = @()

    Write-Info "Missing configuration detected - starting interactive setup."
    Write-Info "Existing, non-empty files are preserved; only the gaps are filled."
    Write-Host ""

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
    Write-ConfigFile -Path (Join-Path $configDir "bootstrap.yaml") -Content $yamlContent

    # --- Generate bootstrap.test.yaml ---
    $testYamlLines = @()
    $testYamlLines += "master_queue:"
    $testYamlLines += "  name: `"Graveboards Queue`""
    $testYamlLines += "  description: `"Master queue for beatmaps to receive leaderboards`""
    $testYamlLines += "  user_id: 1"
    $testYamlLines += "extra_queues: []"
    $testYamlLines += "initial_users:"
    $testYamlLines += "  - user_id: 1"
    $testYamlLines += "    roles: [admin]"
    $testYamlLines += "    generate_api_key: true"
    $testYamlLines += "    enable_score_fetcher: true"
    $testYamlLines += "  - user_id: 2"
    $testYamlLines += "    roles: [admin]"
    $testYamlLines += "    generate_api_key: true"
    $testYamlLines += "    enable_score_fetcher: true"
    $testYamlLines += "initial_roles:"
    $testYamlLines += "  - admin"
    $testYamlLines += "setup_steps:"
    $testYamlLines += "  - create_database"
    $testYamlLines += "  - seed_roles"
    $testYamlLines += "  - seed_users"
    $testYamlLines += "  - seed_api_keys"
    $testYamlLines += "  - seed_queues"
    $testYamlContent = $testYamlLines -join "`n"
    Write-ConfigFile -Path (Join-Path $configDir "bootstrap.test.yaml") -Content $testYamlContent

    # Create .env for direct Python dev mode
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
    Write-ConfigFile -Path (Join-Path $BACKEND_DIR ".env") -Content $envDevContent

    # Create .env.test
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
    Write-ConfigFile -Path (Join-Path $BACKEND_DIR ".env.test") -Content $envTestContent

    # Create .env for deploy orchestrator
    $HostUid = & id -u 2>$null
    if (-not $HostUid -or $HostUid -eq "") { $HostUid = "1000" }
    $HostGid = & id -g 2>$null
    if (-not $HostGid -or $HostGid -eq "") { $HostGid = "1000" }

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

# HOST USER (auto-set - prevents bind-mount permission issues in dev/test)
HOST_UID=$HostUid
HOST_GID=$HostGid
"@
    Write-ConfigFile -Path (Join-Path $SCRIPT_DIR ".env") -Content $envDeployContent

    Write-Host ""
    if ($script:CreatedFiles.Count -gt 0) {
        Write-Success "Created $($script:CreatedFiles.Count) configuration file(s):"
        foreach ($f in $script:CreatedFiles) { Write-Host "  + $f" }
    }
    if ($script:SkippedFiles.Count -gt 0) {
        Write-Info "Preserved $($script:SkippedFiles.Count) existing file(s) - left untouched:"
        foreach ($f in $script:SkippedFiles) { Write-Host "  = $f" }
    }
    Write-Host ""
    Write-Host "You have been added as admin user $OSU_USER_ID."
    if ($ExtraQueues.Count -gt 0) {
        Write-Host "  $($ExtraQueues.Count) extra queue(s) configured."
    }
    if ($ExtraAdmins.Count -gt 0) {
        Write-Host "  $($ExtraAdmins.Count) additional admin user(s) configured."
    }
    Write-Host ""
}

# Fill any missing config files. No-op (and silent) when everything already exists,
# so this is safe to run on every invocation without clobbering populated configs.
Generate-ConfigFiles

# =========================
# Help
# =========================

function Show-Help {
    Write-Host @"
Graveboards Deployment Script

Usage: .\deploy.ps1 [command] [args...]

Commands:
  up [mode] [--follow|-f] [--build] [--no-monitoring] [--nas] [--traefik] [service...]  - Start services (default: dev)
  down [mode] [--no-monitoring] [--nas] [--traefik] [service...]              - Stop services (default: all)
  build [mode] [--no-monitoring] [--nas] [--traefik] [service...]             - Build images (default: dev)
  pull [repo...]                                          - Git pull repos (all or: backend, frontend, deploy)
  force-pull [repo...]                                    - Force reset repos to origin
  deploy [mode] [--follow|-f] [--no-monitoring] [--nas] [--traefik] - Full pipeline: down + pull + build + up
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
  --monitoring-traefik    - Include Traefik routes for monitoring services (prod only)
  --no-frontend            - Exclude frontend service (starts backend + infra only)

Services (for up, down, build, logs):
  all      - All services
  backend  - Backend service
  frontend - Frontend service
  postgres - PostgreSQL database
  redis    - Redis cache

Examples:
  .\deploy.ps1 up dev                           # Start dev mode (detached + follow logs)
  .\deploy.ps1 up dev --follow                  # Start dev mode (foreground)
  .\deploy.ps1 up dev --no-frontend             # Start backend + infra only (skip frontend)
  .\deploy.ps1 up dev backend                   # Start only backend in dev
  .\deploy.ps1 up prod                          # Start prod (no NAS, no Traefik, monitoring internal-only)
  .\deploy.ps1 up prod --nas                    # Start prod with NAS volumes
  .\deploy.ps1 up prod --traefik                # Start prod with Traefik (Grafana on grafana.graveboards.net)
  .\deploy.ps1 up prod --nas --traefik          # Start prod with NAS + Traefik
  .\deploy.ps1 down prod                        # Stop prod mode
  .\deploy.ps1 build test                       # Build test images
  .\deploy.ps1 pull                             # Pull all repos
  .\deploy.ps1 pull backend deploy              # Pull specific repos
  .\deploy.ps1 force-pull                       # Force update all repos
  .\deploy.ps1 deploy prod --nas --traefik      # Full prod deployment with NAS + Traefik
  .\deploy.ps1 deploy prod --follow             # Full deployment with foreground logs
  .\deploy.ps1 logs dev backend                 # View dev backend logs
  .\deploy.ps1 test                             # Run tests
  .\deploy.ps1 status                           # Show status
  .\deploy.ps1 clean                            # Remove volumes and images

For more information, see README.md
"@
}

# =========================
# Docker checks
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

# =========================
# Argument parser
# =========================

function Parse-ModeAndFlags {
    param(
        [string[]]$InputArgs
    )

    $result = [PSCustomObject]@{
        Mode = "dev"
        Follow = "false"
        NoMonitoring = "false"
        Nas = "false"
        Traefik = "false"
        MonitoringTraefik = "false"
        Build = "false"
        NoFrontend = "false"
        Extra = @()
    }

    foreach ($arg in $InputArgs) {
        if ($arg -match '^(dev|prod|test)$' -and $result.Mode -eq "dev") {
            $result.Mode = $arg
        } elseif ($arg -match '^(--follow|-f)$') {
            $result.Follow = "true"
        } elseif ($arg -eq "--no-monitoring") {
            $result.NoMonitoring = "true"
        } elseif ($arg -eq "--nas") {
            $result.Nas = "true"
        } elseif ($arg -eq "--traefik") {
            $result.Traefik = "true"
        } elseif ($arg -eq "--monitoring-traefik") {
            $result.MonitoringTraefik = "true"
        } elseif ($arg -eq "--build") {
            $result.Build = "true"
        } elseif ($arg -eq "--no-frontend") {
            $result.NoFrontend = "true"
        } else {
            $result.Extra += $arg
        }
    }
    return $result
}

# =========================
# Command implementations
# =========================

function Cmd-Up {
    param([string[]]$InputArgs)

    $parsed = Parse-ModeAndFlags -InputArgs $InputArgs
    $mode = $parsed.Mode; $follow = $parsed.Follow; $noMonitoring = $parsed.NoMonitoring; $nas = $parsed.Nas; $traefik = $parsed.Traefik; $monitoringTraefik = $parsed.MonitoringTraefik; $build = $parsed.Build; $noFrontend = $parsed.NoFrontend; $extra = $parsed.Extra

    if ($traefik -eq "true") {
        try {
            docker network inspect traefik-proxy | Out-Null
        } catch {
            Write-Error "Traefik proxy network not found!"
            Write-Info "Make sure Traefik is running and has created the 'traefik-proxy' network"
            exit 1
        }
    }

    $buildArgs = @()
    if ($build -eq "true") {
        $buildArgs += "--build"
    }

    if ($follow -eq "false") {
        Write-Info "Starting Graveboards in $mode mode..."
        if ($mode -ne "test") {
            Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs (@("up") + $buildArgs + "-d" + $extra)
            Write-Success "Services started!"
            Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs (@("logs", "-f") + $extra)
        } else {
            Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs (@("--profile", "test", "up", "--build") + $extra)
        }
    } else {
        Write-Info "Starting Graveboards in $mode mode (foreground)..."
        if ($mode -ne "test") {
            $composeFiles = Build-ComposeArgs -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend
            if ($COMPOSE_CMD.Count -gt 1) {
                $script:COMPOSE_PROCESS_PID = (Start-Process -FilePath $COMPOSE_CMD[0] -ArgumentList (@("compose") + $composeFiles + @("up") + $buildArgs + $extra) -NoNewWindow -PassThru).Id
            } else {
                $script:COMPOSE_PROCESS_PID = (Start-Process -FilePath $COMPOSE_CMD[0] -ArgumentList ($composeFiles + @("up") + $buildArgs + $extra) -NoNewWindow -PassThru).Id
            }
        } else {
            $testComposeFiles = @("-f", "$SCRIPT_DIR/docker-compose.test.yml")
            if ($COMPOSE_CMD.Count -gt 1) {
                $script:COMPOSE_PROCESS_PID = (Start-Process -FilePath $COMPOSE_CMD[0] -ArgumentList (@("compose") + $testComposeFiles + @("up", "--profile", "test", "--build") + $extra) -NoNewWindow -PassThru).Id
            } else {
                $script:COMPOSE_PROCESS_PID = (Start-Process -FilePath $COMPOSE_CMD[0] -ArgumentList ($testComposeFiles + @("up", "--profile", "test", "--build") + $extra) -NoNewWindow -PassThru).Id
            }
        }
        Wait-Process -Id $script:COMPOSE_PROCESS_PID
    }
}

function Cmd-Down {
    param([string[]]$InputArgs)

    $parsed = Parse-ModeAndFlags -InputArgs $InputArgs
    $mode = $parsed.Mode; $noMonitoring = $parsed.NoMonitoring; $nas = $parsed.Nas; $traefik = $parsed.Traefik; $monitoringTraefik = $parsed.MonitoringTraefik; $build = $parsed.Build; $noFrontend = $parsed.NoFrontend; $extra = $parsed.Extra

    Write-Info "Stopping Graveboards services..."

    if ($extra.Count -gt 0) {
        Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs (@("down") + $extra)
    } else {
        Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("down")
    }
    Write-Success "Services stopped!"
}

function Cmd-Build {
    param([string[]]$InputArgs)

    $parsed = Parse-ModeAndFlags -InputArgs $InputArgs
    $mode = $parsed.Mode; $noMonitoring = $parsed.NoMonitoring; $nas = $parsed.Nas; $traefik = $parsed.Traefik; $monitoringTraefik = $parsed.MonitoringTraefik; $build = $parsed.Build; $noFrontend = $parsed.NoFrontend; $extra = $parsed.Extra

    Write-Info "Building Graveboards images for $mode mode..."

    if ($extra.Count -gt 0) {
        Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs (@("build") + $extra)
    } else {
        Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("build")
    }

    Cleanup-SpecCache
    Write-Success "Images built!"
}

function Cmd-Pull {
    param([string[]]$InputArgs)

    if ($InputArgs.Count -eq 0) {
        Write-Info "Pulling all repositories..."
        if (-not (Git-PullRepo -Repo $BACKEND_DIR))  { return $false }
        if (-not (Git-PullRepo -Repo $FRONTEND_DIR)) { return $false }
        if (-not (Git-PullRepo -Repo $SCRIPT_DIR))   { return $false }
    } else {
        foreach ($repo in $InputArgs) {
            switch ($repo) {
                "backend"  { if (-not (Git-PullRepo -Repo $BACKEND_DIR))  { return $false } }
                "frontend" { if (-not (Git-PullRepo -Repo $FRONTEND_DIR)) { return $false } }
                "deploy"   { if (-not (Git-PullRepo -Repo $SCRIPT_DIR))   { return $false } }
                default {
                    Write-Error "Unknown repository: $repo"
                    Write-Info "Valid repositories: backend, frontend, deploy"
                    return $false
                }
            }
        }
    }
    Write-Success "Repositories updated!"
    return $true
}

function Cmd-ForcePull {
    param([string[]]$InputArgs)

    if ($InputArgs.Count -eq 0) {
        Write-Info "Force updating all repositories..."
        Git-ForcePullRepo -Repo $BACKEND_DIR
        Git-ForcePullRepo -Repo $FRONTEND_DIR
        Git-ForcePullRepo -Repo $SCRIPT_DIR
    } else {
        foreach ($repo in $InputArgs) {
            switch ($repo) {
                "backend" { Git-ForcePullRepo -Repo $BACKEND_DIR }
                "frontend" { Git-ForcePullRepo -Repo $FRONTEND_DIR }
                "deploy" { Git-ForcePullRepo -Repo $SCRIPT_DIR }
                default {
                    Write-Error "Unknown repository: $repo"
                    Write-Info "Valid repositories: backend, frontend, deploy"
                    exit 1
                }
            }
        }
    }
    Write-Success "Repositories force updated!"
}

function Cmd-Deploy {
    param([string[]]$InputArgs)

    $parsed = Parse-ModeAndFlags -InputArgs $InputArgs
    $mode = $parsed.Mode; $follow = $parsed.Follow; $noMonitoring = $parsed.NoMonitoring; $nas = $parsed.Nas; $traefik = $parsed.Traefik; $monitoringTraefik = $parsed.MonitoringTraefik; $build = $parsed.Build; $noFrontend = $parsed.NoFrontend; $extra = $parsed.Extra

    if ($traefik -eq "true") {
        try {
            docker network inspect traefik-proxy | Out-Null
        } catch {
            Write-Error "Traefik proxy network not found!"
            Write-Info "Make sure Traefik is running and has created the 'traefik-proxy' network"
            exit 1
        }
    }

    Write-Info "Stopping services..."
    Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("down")

    Write-Info "Pulling latest code..."
    $pullArgs = @()
    if (-not (Cmd-Pull -InputArgs $pullArgs)) {
        Write-Error "Deployment aborted because one or more repositories could not be updated."
        exit 1
    }

    Write-Info "Building images..."
    Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("build")
    Cleanup-SpecCache

    Write-Info "Starting services..."
    if ($follow -eq "true") {
        $composeFiles = @()
        switch ($mode) {
            "dev" { $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.yml" }
            "prod" {
                $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.prod.yml"
                if ($nas -eq "true") { $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.prod.nas.yml" }
                if ($traefik -eq "true") { $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.prod.traefik.yml" }
            }
            "test" { $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.test.yml" }
        }
        if ($mode -ne "test") {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.yml"
            if ($mode -eq "dev") {
                $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.ports.yml"
            }
            if ($monitoringTraefik -eq "true") {
                $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.traefik.yml"
            }
        }
        if ($mode -eq "prod") {
            $composeFiles += "-f", "$SCRIPT_DIR/docker-compose.monitoring.prod.yml"
        }
        if ($COMPOSE_CMD.Count -gt 1) {
            $script:COMPOSE_PROCESS_PID = (Start-Process -FilePath $COMPOSE_CMD[0] -ArgumentList (@("compose") + $composeFiles + @("up", "--build")) -NoNewWindow -PassThru).Id
        } else {
            $script:COMPOSE_PROCESS_PID = (Start-Process -FilePath $COMPOSE_CMD[0] -ArgumentList ($composeFiles + @("up", "--build")) -NoNewWindow -PassThru).Id
        }
        Wait-Process -Id $script:COMPOSE_PROCESS_PID
    } else {
        Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("up", "-d")
        Write-Success "Services started!"
        Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f")
    }

    $deployText = "deploy ${mode} by ${env:USERNAME} @ $(Get-Date -Format 'HH:mm')"
    Invoke-GrafanaAnnotation -Text $deployText -Tags "deploy,graveboards"
}

function Cmd-Logs {
    param([string[]]$InputArgs)

    $parsed = Parse-ModeAndFlags -InputArgs $InputArgs
    $mode = $parsed.Mode; $noMonitoring = $parsed.NoMonitoring; $nas = $parsed.Nas; $traefik = $parsed.Traefik; $monitoringTraefik = $parsed.MonitoringTraefik; $build = $parsed.Build; $noFrontend = $parsed.NoFrontend; $extra = $parsed.Extra

    $service = "all"
    if ($extra.Count -gt 0) {
        $service = $extra[0]
    }

    switch ($service) {
        "all" { Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f") }
        "backend" { Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f", "backend") }
        "frontend" { Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f", "frontend") }
        "postgres" { Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f", "postgresql") }
        "postgresql" { Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f", "postgresql") }
        "redis" { Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f", "redis") }
        default {
            Write-Info "Service '$service' not found. Showing all logs..."
            Invoke-Compose -Mode $mode -NoMonitoring $noMonitoring -Nas $nas -Traefik $traefik -MonitoringTraefik $monitoringTraefik -NoFrontend $noFrontend -ExtraArgs @("logs", "-f")
        }
    }
}

function Cmd-Test {
    param([string[]]$InputArgs)

    $Logfile = ""
    $NoCleanup = $false
    $NoLogFile = $false
    $Quiet = $false
    $i = 0

    while ($i -lt $InputArgs.Count) {
        $arg = $InputArgs[$i]
        if ($arg -eq "--log-file") {
            $i++
            if ($i -lt $InputArgs.Count) {
                $Logfile = $InputArgs[$i]
            }
        } elseif ($arg -match '^--log-file=(.+)$') {
            $Logfile = $Matches[1]
        } elseif ($arg -eq "--no-cleanup") {
            $NoCleanup = $true
        } elseif ($arg -eq "--no-log") {
            $NoLogFile = $true
        } elseif ($arg -eq "--quiet") {
            $Quiet = $true
        } elseif ($arg -eq "--help") {
            Show-Help
            exit 0
        } else {
            Write-Error "Unknown test option: $arg"
            Show-Help
            exit 1
        }
        $i++
    }

    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if (-not $Logfile -and -not $NoLogFile) {
        $Logfile = Join-Path $SCRIPT_DIR "test-output-${Timestamp}.log"
    }

    Write-Info "Running Graveboards tests in Docker..."
    if ($Logfile) {
        Write-Info "Log file: $Logfile"
    } else {
        Write-Info "Log file: disabled (--no-log)"
    }

    if ($Quiet) {
        Write-Info "Building test image (quiet)..."
        docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test build --quiet 2>$null
    } else {
        Write-Info "Building test image..."
        docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" --profile test build
    }

    Write-Info "Starting test services (PostgreSQL, Redis, and backend)..."
    Invoke-Compose -Mode "test" -ExtraArgs @("--profile", "test", "up", "-d", "--quiet-pull")

    Write-Info "Waiting for test services to be healthy..."
    $healthRetries = 0
    $maxHealthRetries = 30
    $healthy = $false
    while ($healthRetries -lt $maxHealthRetries -and -not $healthy) {
        $psOutput = docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" ps postgresql redis 2>$null
        if ($psOutput -match "healthy") {
            $healthy = $true
        }
        $healthRetries++
        Start-Sleep -Seconds 2
    }

    if (-not $healthy) {
        Write-Error "Test services did not become healthy in time"
        docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" logs backend 2>&1
        if (-not $NoCleanup) {
            Invoke-Compose -Mode "test" -ExtraArgs @("down", "-v", "--remove-orphans")
        }
        exit 1
    }

    $exitCode = 0
    if ($Logfile) {
        Write-Info "Running tests (real-time output to terminal and $(Split-Path $Logfile -Leaf))..."
        $composeArgs = @("logs", "-f", "backend")
        $null = docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" @composeArgs 2>&1 | Tee-Object -FilePath $Logfile
        $exitCode = $LASTEXITCODE
    } else {
        Write-Info "Running tests (real-time output to terminal)..."
        $composeArgs = @("logs", "-f", "backend")
        $null = docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" @composeArgs 2>&1
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -ne 0) {
        Write-Error "Unexpected non-zero exit code: $exitCode (logs may have been truncated)"
    }

    $backendContainerId = docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" ps -q backend 2>$null | Select-Object -First 1
    if ($backendContainerId) {
        $containerExitCode = docker inspect --format '{{.State.ExitCode}}' $backendContainerId 2>$null
        if ($containerExitCode -and $containerExitCode -ne 0) {
            $exitCode = $containerExitCode
        }
    }

    if ($exitCode -eq 0) {
        Write-Success "Tests passed!"
    } else {
        Write-Error "Tests failed! Exit code: $exitCode"
        if ($Logfile) {
            Write-Error "Full log saved to: $Logfile"
        }
    }

    if ($NoCleanup) {
        Write-Warning "Skipping cleanup (--no-cleanup). Containers still running."
    } else {
        Write-Info "Test completed, cleaning up..."
        Invoke-Compose -Mode "test" -ExtraArgs @("down", "-v", "--remove-orphans")
    }

    exit $exitCode
}

function Cmd-Status {
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

    Write-Host "`nDeploy Repository:" -ForegroundColor $ColorInfo
    if (Test-Path $SCRIPT_DIR) {
        Write-Success "Found at $SCRIPT_DIR"
    } else {
        Write-Error "Not found at $SCRIPT_DIR"
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
    docker ps -a --filter "name=graveboards" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}"
}

function Cmd-Clean {
    Write-Warning "This will remove all volumes and images! (excluding prod)"
    $confirm = Read-Host "Are you sure? (yes/no)"

    if ($confirm -eq "yes") {
        Write-Info "Removing volumes and images..."

        $composeArgs1 = @("-f", "$SCRIPT_DIR/docker-compose.yml", "-f", "$SCRIPT_DIR/docker-compose.monitoring.yml", "down", "-v", "--remove-orphans")
        $composeArgs2 = @("-f", "$SCRIPT_DIR/docker-compose.test.yml", "down", "-v", "--remove-orphans")
        $composeArgs3 = @("-f", "$SCRIPT_DIR/docker-compose.prod.yml", "-f", "$SCRIPT_DIR/docker-compose.prod.traefik.yml", "-f", "$SCRIPT_DIR/docker-compose.monitoring.yml", "down", "--remove-orphans")

        if ($COMPOSE_CMD.Count -gt 1) {
            & docker compose @composeArgs1
            & docker compose @composeArgs2
            & docker compose @composeArgs3
        } else {
            & docker-compose @composeArgs1
            & docker-compose @composeArgs2
            & docker-compose @composeArgs3
        }

        $imageIds = docker images -q graveboards* 2>$null
        if ($imageIds) {
            docker rmi -f $imageIds
        }
        Write-Success "Cleaned up environment"
    } else {
        Write-Info "Clean aborted"
    }
}

# =========================
# Main execution
# =========================

Write-Host "Graveboards Deployment Script" -ForegroundColor $ColorInfo
Write-Host "=============================" -ForegroundColor $ColorInfo
Write-Host ""

switch ($Command) {
    "up" { Cmd-Up -InputArgs $Args }
    "down" { Cmd-Down -InputArgs $Args }
    "build" { Cmd-Build -InputArgs $Args }
    "pull" { if (-not (Cmd-Pull -InputArgs $Args)) { exit 1 } }
    "force-pull" { Cmd-ForcePull -InputArgs $Args }
    "deploy" { Cmd-Deploy -InputArgs $Args }
    "logs" { Cmd-Logs -InputArgs $Args }
    "test" { Cmd-Test -InputArgs $Args }
    "status" { Cmd-Status }
    "clean" { Cmd-Clean }
    "help" { Show-Help }
    default {
        Write-Error "Unknown command: $Command"
        Show-Help
        exit 1
    }
}

exit 0
