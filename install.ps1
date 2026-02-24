<#
.SYNOPSIS
    Guided installation for safe-claude on Windows.

.DESCRIPTION
    1. Checks that Docker Desktop is installed and running
    2. Builds the 'safe-claude' Docker image
    3. Installs safe-claude.ps1 and a safe-claude.bat wrapper to a chosen directory
    4. Adds that directory to your user PATH

.NOTES
    If PowerShell blocks this script due to execution policy, run:
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    Or launch the installer with:
        powershell -ExecutionPolicy Bypass -File install.ps1
#>

$IMAGE_NAME  = "safe-claude"
$DEFAULT_DIR = "$env:USERPROFILE\AppData\Local\Programs\safe-claude"

# ── helpers ───────────────────────────────────────────────────────────────────

function Write-Info    { param([string]$m) Write-Host "[safe-claude] $m" }
function Write-Success { param([string]$m) Write-Host "[safe-claude] OK  $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m) Write-Host "[safe-claude] !   $m" -ForegroundColor Yellow }
function Write-Err     { param([string]$m) Write-Host "[safe-claude] Error: $m" -ForegroundColor Red; exit 1 }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── step 1: prerequisites ─────────────────────────────────────────────────────

Write-Host ""
Write-Host "==========================================="
Write-Host "  safe-claude installer (Windows)"
Write-Host "==========================================="
Write-Host ""

Write-Info "Checking prerequisites..."

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker is not installed or not on PATH.`n  Install Docker Desktop from https://www.docker.com and re-run this script."
}

$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker daemon is not running. Please start Docker Desktop and re-run this script."
}

Write-Success "Docker is available and running."

# ── step 2: build the Docker image ───────────────────────────────────────────

Write-Host ""
$null = docker image inspect $IMAGE_NAME 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warn "Docker image '$IMAGE_NAME' already exists."
    $rebuild = Read-Host "         Rebuild it? [y/N]"
} else {
    $rebuild = "y"
}

if ($rebuild -match '^[Yy]$') {
    Write-Info "Building Docker image '$IMAGE_NAME' (this may take a few minutes)..."
    docker build -t $IMAGE_NAME $ScriptDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker build failed. Check the output above for details."
    }
    Write-Success "Docker image '$IMAGE_NAME' built successfully."
} else {
    Write-Info "Skipping image build."
}

# ── step 3: choose install directory ─────────────────────────────────────────

Write-Host ""
Write-Info "Where should the 'safe-claude' command be installed?"
Write-Info "This directory will be added to your user PATH."
$installDir = Read-Host "         Install directory [$DEFAULT_DIR]"
if ([string]::IsNullOrWhiteSpace($installDir)) {
    $installDir = $DEFAULT_DIR
}
$installDir = $installDir.TrimEnd('\').TrimEnd('/')

if (-not (Test-Path $installDir)) {
    $create = Read-Host "         Directory '$installDir' does not exist. Create it? [y/N]"
    if ($create -match '^[Yy]$') {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        Write-Success "Created directory '$installDir'."
    } else {
        Write-Err "Installation cancelled."
    }
}

# ── step 4: copy files ────────────────────────────────────────────────────────

$destPs1 = Join-Path $installDir "safe-claude.ps1"
$destBat = Join-Path $installDir "safe-claude.bat"

Write-Info "Installing to '$installDir'..."

Copy-Item -Path (Join-Path $ScriptDir "safe-claude.ps1") -Destination $destPs1 -Force

# .bat wrapper so 'safe-claude' works from CMD and PowerShell without typing .ps1
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0safe-claude.ps1" %*
"@ | Set-Content -Path $destBat -Encoding ASCII

Write-Success "Files installed."

# ── step 5: add to PATH ───────────────────────────────────────────────────────

$currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$installDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$currentPath;$installDir", "User")
    Write-Success "Added '$installDir' to your user PATH."
    Write-Warn "Restart your terminal for the PATH change to take effect."
} else {
    Write-Info "'$installDir' is already on your PATH."
}

# ── step 6: verify ────────────────────────────────────────────────────────────

Write-Host ""
$refreshedPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($refreshedPath -like "*$installDir*") {
    Write-Success "Installation complete."
} else {
    Write-Warn "Could not verify PATH. You may need to add '$installDir' manually."
}

# ── done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "==========================================="
Write-Host "  All done!"
Write-Host "==========================================="
Write-Host ""
Write-Host "  Restart your terminal, then use:"
Write-Host ""
Write-Host "    safe-claude C:\path\to\your\project"
Write-Host ""
Write-Host "  This will create a sandboxed Docker container for that folder"
Write-Host "  (if one doesn't exist yet) and drop you into a bash session"
Write-Host "  with Claude Code ready to use."
Write-Host ""
