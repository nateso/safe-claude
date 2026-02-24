<#
.SYNOPSIS
    Enter (or create) a safe-claude Docker container for a given folder.

.DESCRIPTION
    safe-claude.ps1 <path_to_folder>

    - Resolves the folder to an absolute path
    - Derives a stable container name from that path
    - Creates the container if it does not exist yet
    - Starts the container if it is stopped
    - Drops you into a bash session inside the container

    Run install.ps1 first to build the 'safe-claude' Docker image.

.PARAMETER FolderPath
    Path to the folder you want Claude to work in.
#>

param(
    [Parameter(Position = 0)]
    [string]$FolderPath
)

$IMAGE_NAME = "safe-claude"

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Info  { param([string]$m) Write-Host $m }
function Write-Err   { param([string]$m) Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function Get-ContainerName {
    param([string]$AbsPath)
    $base = (Split-Path -Leaf $AbsPath).ToLower() -replace '[^a-z0-9_-]', '-'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($AbsPath)
    $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    $hash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLower().Substring(0, 8)
    return "safe-claude-$base-$hash"
}

# ── argument validation ───────────────────────────────────────────────────────

if (-not $FolderPath) {
    Write-Host "Usage: safe-claude <path_to_folder>"
    Write-Host ""
    Write-Host "  Enters the Docker container for <path_to_folder>."
    Write-Host "  Creates the container if it does not exist yet."
    Write-Host ""
    Write-Host "  Run install.ps1 first to build the '$IMAGE_NAME' Docker image."
    exit 1
}

try {
    $AbsPath = (Resolve-Path -Path $FolderPath -ErrorAction Stop).Path
} catch {
    Write-Err "Path does not exist: $FolderPath"
}

if (-not (Test-Path -Path $AbsPath -PathType Container)) {
    Write-Err "Not a directory: $FolderPath"
}

$ContainerName = Get-ContainerName -AbsPath $AbsPath

# ── pre-flight checks ─────────────────────────────────────────────────────────

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker is not installed or not on PATH."
}

$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker daemon is not running. Please start Docker Desktop and try again."
}

$null = docker image inspect $IMAGE_NAME 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "'$IMAGE_NAME' Docker image not found. Run install.ps1 to build it first."
}

# ── container lifecycle ───────────────────────────────────────────────────────

$null = docker container inspect $ContainerName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Info "No container found for this folder. Creating '$ContainerName'..."
    docker run -dit `
        --name $ContainerName `
        -v "${AbsPath}:/workspace" `
        $IMAGE_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create container."
    }
    Write-Info "Container created."
} else {
    $Status = docker container inspect --format '{{.State.Status}}' $ContainerName
    if ($Status -ne "running") {
        Write-Info "Starting container '$ContainerName'..."
        docker start $ContainerName | Out-Null
    }
}

# ── enter the container ───────────────────────────────────────────────────────

Write-Info "Entering container '$ContainerName' (folder: $AbsPath)..."
Write-Info "Type 'exit' or press Ctrl+D to leave the container."
Write-Info ""
docker exec -it $ContainerName claude
