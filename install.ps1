<#
.SYNOPSIS
    Guided installation for safe-claude on Windows.

.DESCRIPTION
    1. Checks that Docker Desktop is installed and running
    2. Builds the 'safe-claude' Docker image
    3. Installs safe-claude.ps1 and a safe-claude.bat wrapper to a chosen directory
    4. Adds that directory to your user PATH

.PARAMETER InstallDir
    Where to put the 'safe-claude' command. Defaults to a per-user location that
    needs no administrator rights. The installer creates it and adds it to PATH.

.NOTES
    If PowerShell blocks this script due to execution policy, run:
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    Or launch the installer with:
        powershell -ExecutionPolicy Bypass -File install.ps1
#>

param(
    [string]$InstallDir
)

$IMAGE_NAME   = "safe-claude"
$DEFAULT_DIR  = Join-Path $env:LOCALAPPDATA "Programs\safe-claude"
$VERSION_FILE = Join-Path $env:LOCALAPPDATA "safe-claude\version"

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

# Resolve the source commit up front: it is stamped into the image below and
# recorded for 'safe-claude --version' further down.
$sha = (git -C $ScriptDir rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $sha) { $sha = 'unknown' } else { $sha = $sha.Trim() }

# ── step 2: build the Docker image ───────────────────────────────────────────

Write-Host ""
$imgJson = docker image inspect $IMAGE_NAME 2>$null
if ($LASTEXITCODE -eq 0 -and $imgJson) {
    # Compare the image's stamped commit with this checkout. An image built from
    # different source is the common cause of "I reinstalled but nothing
    # changed", so recommend rebuilding rather than defaulting to skip.
    $imgSha = 'unknown'
    try {
        $labels = (@($imgJson | ConvertFrom-Json)[0]).Config.Labels
        if ($labels) {
            $prop = $labels.PSObject.Properties['org.opencontainers.image.revision']
            if ($prop -and $prop.Value) { $imgSha = [string]$prop.Value }
        }
    } catch {
        # Unparseable inspect output: treat the image as carrying no stamp.
        $imgSha = 'unknown'
    }

    if ($sha -ne 'unknown' -and $imgSha -eq $sha) {
        Write-Warn "Docker image '$IMAGE_NAME' already exists and matches this checkout ($($sha.Substring(0,8)))."
        $rebuild = Read-Host "         Rebuild it anyway? [y/N]"
        if ([string]::IsNullOrWhiteSpace($rebuild)) { $rebuild = 'N' }
    } else {
        $shortImg = if ($imgSha.Length -ge 8) { $imgSha.Substring(0,8) } else { $imgSha }
        $shortSrc = if ($sha.Length -ge 8) { $sha.Substring(0,8) } else { $sha }
        Write-Warn "Docker image '$IMAGE_NAME' exists but was built from $shortImg, not this checkout ($shortSrc)."
        Write-Warn "Rebuilding keeps the image in step with the command being installed."
        $rebuild = Read-Host "         Rebuild it? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($rebuild)) { $rebuild = 'Y' }
    }
} else {
    $rebuild = "y"
}

if ($rebuild -match '^[Yy]$') {
    Write-Info "Building Docker image '$IMAGE_NAME' (this may take a few minutes)..."
    # --pull so a rebuild actually refreshes the base image rather than reusing a
    # stale local copy.
    docker build --pull --build-arg "SAFE_CLAUDE_VERSION=$sha" -t $IMAGE_NAME $ScriptDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker build failed. Check the output above for details."
    }
    Write-Success "Docker image '$IMAGE_NAME' built successfully."
} else {
    Write-Info "Skipping image build."
}

# ── step 3: install directory ────────────────────────────────────────────────

# PowerShell variable names are case-insensitive, so this must NOT be called
# $installDir: that is the -InstallDir parameter, and assigning the default to it
# would discard the caller's choice.
$usingDefault = [string]::IsNullOrWhiteSpace($InstallDir)
if ($usingDefault) { $targetDir = $DEFAULT_DIR } else { $targetDir = $InstallDir }
$targetDir = $targetDir.TrimEnd('\').TrimEnd('/')

Write-Host ""
Write-Info "Installing the 'safe-claude' command to:"
Write-Host "               $targetDir"
if ($usingDefault) {
    Write-Host "             (to put it somewhere else, re-run with:  -InstallDir <path>)"
}

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Write-Success "Created directory '$targetDir'."
}

# ── step 4: copy files ────────────────────────────────────────────────────────

$destPs1 = Join-Path $targetDir "safe-claude.ps1"
$destBat = Join-Path $targetDir "safe-claude.bat"

Copy-Item -Path (Join-Path $ScriptDir "safe-claude.ps1") -Destination $destPs1 -Force

# .bat wrapper so 'safe-claude' works from CMD and PowerShell without typing .ps1
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0safe-claude.ps1" %*
"@ | Set-Content -Path $destBat -Encoding ASCII

Write-Success "Files installed."

# ── step 4b: record installed version ─────────────────────────────────────────
# Store the source commit SHA so 'safe-claude update' can detect "already up to
# date" and 'safe-claude --version' can report it.
$verDir = Split-Path -Parent $VERSION_FILE
if (-not (Test-Path $verDir)) { New-Item -ItemType Directory -Path $verDir -Force | Out-Null }
Set-Content -Path $VERSION_FILE -Value $sha
if ($sha -eq 'unknown') {
    Write-Warn "Not a git checkout - recorded version as 'unknown'."
} else {
    Write-Success "Recorded version $($sha.Substring(0,8))."
}

# ── step 5: add to PATH ───────────────────────────────────────────────────────

$currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$targetDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$currentPath;$targetDir", "User")
    Write-Success "Added '$targetDir' to your user PATH."
    Write-Warn "Restart your terminal for the PATH change to take effect."
} else {
    Write-Info "'$targetDir' is already on your PATH."
}

# ── step 6: verify ────────────────────────────────────────────────────────────

Write-Host ""
$refreshedPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($refreshedPath -like "*$targetDir*") {
    Write-Success "Installation complete."
} else {
    Write-Warn "Could not verify PATH. You may need to add '$targetDir' manually."
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
Write-Host "  (if one doesn't exist yet) and launch Claude Code."
Write-Host ""
Write-Host "  Add --dangerously-skip-permissions to run Claude without prompts:"
Write-Host ""
Write-Host "    safe-claude C:\path\to\your\project --dangerously-skip-permissions"
Write-Host ""
